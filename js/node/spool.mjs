// The Node adapter of WasmHost, spool transport: the host's side of a WASI preview 1 module's
// downloads and decompression, through files of a spool directory (see src/WasmHost.jl). No
// import of its own: it wraps the module's WASI `path_open`.
//
// - opening `<spool>/<id>.res` performs the HTTP request of `<spool>/<id>.req` first
//   ("wasm-fetch 1", with `fetch`);
// - opening `<spool>/<id>.dres` decompresses as `<spool>/<id>.dreq` asks ("wasm-decompress 1",
//   with node:zlib).
//
//   const host = wrapWasi(wasi.wasiImport, { preopens, spool: '/work/.wasmhost', mode });
//   const inst = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: host.wasiImport });
//   host.bindMemory(inst.exports.memory);
//
// One wrapper serves both: a `WebAssembly.Suspending` can't be wrapped again from JavaScript.
// `preopens` is the `{ guestPath: hostPath }` given to WASI (fds 3, 4, ... in that order).
// `mode`:
//   - 'jspi': `path_open` is a `WebAssembly.Suspending`: the module waits with its stack
//     suspended; exports that download or decompress must be called through
//     `WebAssembly.promising` (Node 24+ and Bun have it on by default).
//   - 'sync': the work runs on a worker thread while the main thread blocks in `Atomics.wait`.
//     The wait has no timeout: a worker that dies before it takes a job (e.g. a `--require`
//     preload that fails in it) can't be told from one still working, and the module then hangs.
// `fetchImpl` replaces `fetch` (jspi mode only; e.g. to refuse all requests).

import fs from 'node:fs';
import path from 'node:path';
import { parseRequest, formatResult, curlCode } from '../common/fetch.mjs';
import { parseDecompressRequest, formatDecompressAnswer } from '../common/decompress.mjs';
import { makeMapper, guestDir } from './paths.mjs';
import { perform } from './http.mjs';
import { decompressFile, errnoOf } from './decompress.mjs';

export { makeMapper, perform, decompressFile };

const KINDS = [
  { kind: 'fetch', res: '.res', req: '.req' },
  { kind: 'decompress', res: '.dres', req: '.dreq' },
];

// The answer for a job that failed before it ran. A download whose file can't be had (`url`
// set: a path inside the preopens that the file system refuses, e.g. under a regular file)
// fails as the request itself does when it can't open the file.
function failure(kind, err) {
  const message = String(err?.message ?? err);
  if (kind !== 'fetch') return formatDecompressAnswer(errnoOf(err), message);
  return err?.url === undefined
    ? formatResult({ code: 2, message, url: '', status: 0, headers: [] })
    : formatResult({ code: curlCode(err), message, url: err.url, status: 0, headers: [] });
}

// Do one job (host paths mapped) and write its response file. Throws only if that file can't be
// written.
export async function serve(job, { fetchImpl } = {}) {
  let text;
  try {
    if (job.kind === 'fetch') {
      text = formatResult(await perform(job.req, { fetchImpl }));
    } else {
      const [errno, message] = await decompressFile(job.srcHost, job.dstHost, job.format);
      text = formatDecompressAnswer(errno, message);
    }
  } catch (err) {
    text = failure(job.kind, err);
  }
  fs.writeFileSync(job.resHost, text);
}

export function wrapWasi(wasiImport, { preopens = {}, spool, mode = 'jspi', fetchImpl } = {}) {
  if (!spool) throw new Error('wasmhost: no spool directory');
  const map = makeMapper(preopens);
  // (without a trailing slash, as the mapper's preopens: compared with the `dirname` of the paths opened)
  const spoolGuest = guestDir(spool);
  // (resolved as the directory it is for the files opened in it: a link to one is followed)
  fs.mkdirSync(map.toHost(spoolGuest + '/'), { recursive: true });
  let memory = null;
  const decoder = new TextDecoder();
  const original = wasiImport.path_open;
  const stats = { requests: 0, decompress: 0 };

  // { kind, reqHost, resHost } when the path of this `path_open` is a pending response of the
  // spool, else null
  function pending(dirfd, pathOff, pathLen) {
    const dir = map.preopenOf(dirfd);
    if (dir === undefined || memory === null) return null;
    const guest = path.posix.join(dir, decoder.decode(new Uint8Array(memory.buffer, pathOff, pathLen)));
    if (path.posix.dirname(guest) !== spoolGuest) return null;
    const k = KINDS.find((x) => guest.endsWith(x.res));
    if (k === undefined) return null;
    let resHost, reqHost;
    try {
      resHost = map.toHost(guest);
      reqHost = map.toHost(guest.slice(0, -k.res.length) + k.req);
    } catch {
      return null;   // (a link out of the preopens: WASI's own `path_open` answers)
    }
    if (fs.existsSync(resHost) || !fs.existsSync(reqHost)) return null;
    return { kind: k.kind, reqHost, resHost };
  }
  // the job of a pending response (throws for a bad request)
  function prepare(p) {
    const text = fs.readFileSync(p.reqHost, 'utf8');
    if (p.kind === 'fetch') {
      const req = parseRequest(text);
      // (a path outside the preopens refuses the request; any other error is the file's)
      const file = (g) => {
        try { return g ? map.toHost(g) : ''; } catch (err) { throw err?.outside ? err : Object.assign(err, { url: req.url }); }
      };
      req.outputHost = file(req.output);
      req.inputHost = file(req.input);
      stats.requests++;
      return { kind: 'fetch', req, resHost: p.resHost };
    }
    const d = parseDecompressRequest(text);
    stats.decompress++;
    return { kind: 'decompress', srcHost: map.toHost(d.src), dstHost: map.toHost(d.dst), format: d.format, resHost: p.resHost };
  }

  // the response to a request that `prepare` refused. (Never an exception of `path_open`: if
  // the response can't be written, the module finds none, as when a job fails.)
  function refuse(p, err) {
    try { fs.writeFileSync(p.resHost, failure(p.kind, err)); } catch {}
  }

  let path_open;
  if (mode === 'jspi') {
    if (typeof WebAssembly.Suspending !== 'function')
      throw new Error('wasmhost: mode "jspi" needs JavaScript Promise Integration (Node 24+ or Bun)');
    path_open = new WebAssembly.Suspending((...args) => {
      const p = pending(args[0], args[2], args[3]);
      if (p === null) return original(...args);
      return (async () => {
        let job;
        try { job = prepare(p); } catch (err) { refuse(p, err); return original(...args); }
        try { await serve(job, { fetchImpl }); } catch {}
        return original(...args);
      })();
    });
  } else if (mode === 'sync') {
    const sab = new SharedArrayBuffer(4);
    const flag = new Int32Array(sab);
    let worker = null;
    path_open = (...args) => {
      const p = pending(args[0], args[2], args[3]);
      if (p === null) return original(...args);
      let job;
      try { job = prepare(p); } catch (err) { refuse(p, err); return original(...args); }
      worker ??= workerFor(sab);
      Atomics.store(flag, 0, 0);
      worker.postMessage(job);
      Atomics.wait(flag, 0, 0);
      return original(...args);
    };
  } else {
    throw new Error(`wasmhost: mode ${mode}: 'jspi' or 'sync'`);
  }
  return {
    wasiImport: { ...wasiImport, path_open },
    bindMemory(m) { memory = m; },
    stats,
  };
}

// (sync mode) one worker per adapter, doing the jobs; unref'd so it never keeps the process
// alive
let WorkerCtor = null;
function workerFor(sab) {
  WorkerCtor ??= process.getBuiltinModule('node:worker_threads').Worker;
  // (`getBuiltinModule`, not `require`: the source is a module when the process runs with
  // `--input-type=module`, where a `require` fails the worker before it can answer)
  const src = `
    const { parentPort, workerData } = process.getBuiltinModule('node:worker_threads');
    const flag = new Int32Array(workerData.sab);
    let mod = null;
    parentPort.on('message', async (job) => {
      // (the main thread waits without a timeout: woken also when the job failed, e.g. the
      // response file couldn't be written; it then finds no response)
      try {
        mod ??= await import(workerData.self);
        await mod.serve(job);
      } catch {
      } finally {
        Atomics.store(flag, 0, 1); Atomics.notify(flag, 0);
      }
    });`;
  const w = new WorkerCtor(src, { eval: true, workerData: { sab, self: import.meta.url } });
  w.unref();
  return w;
}
