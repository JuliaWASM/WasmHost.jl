// The Node adapter of WasmFetch, transport A (spool): HTTP requests of a WASI preview 1 module
// performed by `fetch`, through files of a spool directory (see `src/WasmFetch.jl` for the
// protocol). No import of
// its own: it wraps the module's WASI `path_open`. Opening `<spool>/<id>.res` performs the
// request of `<spool>/<id>.req` first.
//
//   const fetchHost = wrapWasi(wasi.wasiImport, { preopens, spool: '/work/.wasm-fetch', mode });
//   const inst = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: fetchHost.wasiImport });
//   fetchHost.bindMemory(inst.exports.memory);
//
// `preopens` is the `{ guestPath: hostPath }` given to WASI (fds 3, 4, ... in that order).
// `mode`:
//   - 'jspi': `path_open` is a `WebAssembly.Suspending`: the module waits for `fetch` with its
//     stack suspended; exports that download must be called through `WebAssembly.promising`.
//     Tested on Node (--experimental-wasm-jspi where not on by default); browsers with JSPI
//     need a WASI filesystem under the module for the spool directory (untested).
//   - 'sync': the request runs on a worker thread while the main thread blocks in
//     `Atomics.wait`. Node only (a browser's main thread may not block; a browser worker may).

import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { parseRequest, formatResult, curlCode } from '../common/protocol.mjs';

export { parseRequest, formatResult };

export function makeMapper(preopens) {
  const entries = Object.entries(preopens).map(([g, h]) => [path.posix.normalize(g), h]);
  return {
    // fd -> guest path of a preopen (node:wasi numbers them from 3 in order)
    preopenOf: (fd) => entries[fd - 3]?.[0],
    // a guest path -> the host's, through the longest preopen containing it
    toHost(guest) {
      const g = path.posix.normalize(guest);
      let best = null;
      for (const [gp, hp] of entries)
        if ((g === gp || g.startsWith(gp.endsWith('/') ? gp : gp + '/')) && (!best || gp.length > best[0].length))
          best = [gp, hp];
      if (!best) throw new Error(`wasm-fetch: ${guest} is outside the preopens`);
      return path.join(best[1], path.posix.relative(best[0], g));
    },
  };
}

// Perform one request (host paths already mapped): the result for the `.res` file.
export async function perform(req, { fetchImpl = globalThis.fetch } = {}) {
  try {
    const init = { method: req.method, headers: req.headers, redirect: 'follow' };
    if (Number.isFinite(req.timeout)) init.signal = AbortSignal.timeout(Math.max(1, req.timeout * 1000));
    if (req.inputHost) { init.body = fs.readFileSync(req.inputHost); }
    const r = await fetchImpl(req.url, init);
    if (req.outputHost && r.body) {
      await pipeline(Readable.fromWeb(r.body), fs.createWriteStream(req.outputHost));
    } else if (req.outputHost) {
      fs.writeFileSync(req.outputHost, new Uint8Array());
    } else if (r.body) {
      await r.body.cancel();
    }
    // (fetch joins repeated headers with ", "; set-cookie kept apart, as libcurl gives them)
    const headers = [];
    for (const [k, v] of r.headers) if (k !== 'set-cookie') headers.push([k, v]);
    for (const c of r.headers.getSetCookie?.() ?? []) headers.push(['set-cookie', c]);
    // (fetch has no HTTP version: libcurl's status line for an HTTP/1.1 response)
    return { code: 0, message: '', url: r.url, status: r.status,
             statusLine: `HTTP/1.1 ${r.status}${r.statusText ? ' ' + r.statusText : ''}`, headers };
  } catch (err) {
    const msg = err?.cause?.message ? `${err.message}: ${err.cause.message}` : String(err?.message ?? err);
    return { code: curlCode(err), message: msg, url: req.url, status: 0, statusLine: '', headers: [] };
  }
}

export function wrapWasi(wasiImport, { preopens = {}, spool, mode = 'jspi', fetchImpl } = {}) {
  if (!spool) throw new Error('wasm-fetch: no spool directory');
  const map = makeMapper(preopens);
  const spoolGuest = path.posix.normalize(spool);
  fs.mkdirSync(map.toHost(spoolGuest), { recursive: true });
  let memory = null;
  const decoder = new TextDecoder();
  const original = wasiImport.path_open;
  const stats = { requests: 0 };

  // the host paths of the request `.req` of the response `guest`, or null when `guest` is not a
  // pending response of the spool
  function pending(dirfd, pathOff, pathLen) {
    const dir = map.preopenOf(dirfd);
    if (dir === undefined || memory === null) return null;
    const rel = decoder.decode(new Uint8Array(memory.buffer, pathOff, pathLen));
    const guest = path.posix.join(dir, rel);
    if (path.posix.dirname(guest) !== spoolGuest || !guest.endsWith('.res')) return null;
    const resHost = map.toHost(guest);
    const reqHost = resHost.slice(0, -4) + '.req';
    if (fs.existsSync(resHost) || !fs.existsSync(reqHost)) return null;
    return { reqHost, resHost };
  }
  function prepare(p) {
    const req = parseRequest(fs.readFileSync(p.reqHost, 'utf8'));
    req.outputHost = req.output ? map.toHost(req.output) : '';
    req.inputHost = req.input ? map.toHost(req.input) : '';
    stats.requests++;
    return req;
  }

  let path_open;
  if (mode === 'jspi') {
    if (typeof WebAssembly.Suspending !== 'function')
      throw new Error('wasm-fetch: mode "jspi" needs JavaScript Promise Integration (Node: --experimental-wasm-jspi)');
    path_open = new WebAssembly.Suspending((...args) => {
      const p = pending(args[0], args[2], args[3]);
      if (p === null) return original(...args);
      return (async () => {
        let result;
        try { result = await perform(prepare(p), { fetchImpl }); }
        catch (err) { result = { code: 2, message: String(err?.message ?? err), url: '', status: 0, headers: [] }; }
        fs.writeFileSync(p.resHost, formatResult(result));
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
      let req;
      try { req = prepare(p); }
      catch (err) {
        fs.writeFileSync(p.resHost, formatResult({ code: 2, message: String(err?.message ?? err), url: '', status: 0 }));
        return original(...args);
      }
      worker ??= workerFor(sab);
      Atomics.store(flag, 0, 0);
      worker.postMessage({ req, resHost: p.resHost });
      Atomics.wait(flag, 0, 0);
      return original(...args);
    };
  } else {
    throw new Error(`wasm-fetch: mode ${mode}: 'jspi' or 'sync'`);
  }
  return {
    wasiImport: { ...wasiImport, path_open },
    bindMemory(m) { memory = m; },
    stats,
  };
}

// (sync mode) one worker per adapter, performing the requests; unref'd so it never keeps the
// process alive
let WorkerCtor = null;
function workerFor(sab) {
  WorkerCtor ??= process.getBuiltinModule('node:worker_threads').Worker;
  const src = `
    const { parentPort, workerData } = require('node:worker_threads');
    const flag = new Int32Array(workerData.sab);
    let mod = null;
    parentPort.on('message', async ({ req, resHost }) => {
      mod ??= await import(workerData.self);
      let r;
      try { r = await mod.perform(req); } catch (err) { r = { code: 2, message: String(err), url: req.url, status: 0 }; }
      require('node:fs').writeFileSync(resHost, mod.formatResultForWorker(r));
      Atomics.store(flag, 0, 1); Atomics.notify(flag, 0);
    });`;
  const w = new WorkerCtor(src, { eval: true, workerData: { sab, self: import.meta.url } });
  w.unref();
  return w;
}
export const formatResultForWorker = formatResult;
