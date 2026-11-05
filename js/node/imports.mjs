// The Node adapter of WasmHost, import transport: the same HTTP requests as `spool.mjs`,
// through WasmHost's import library `wasm_host` instead of the spool directory. Needs a module
// compiled with `Config(import_libraries = ["wasm_host"])` and `WasmHost.transport() = :import`.
//
//   const host = makeImports({ preopens });
//   const inst = await WebAssembly.instantiate(mod, { wasi_snapshot_preview1: wasi.wasiImport, ...host.imports });
//   host.bindMemory(inst.exports.memory);
//   await WebAssembly.promising(inst.exports.main)();
//
// (Request bodies from and responses into an `IO` still go through files of the spool
// directory, `WASMHOST_SPOOL`: create it before running the module. Decompression always uses
// the spool directory: give the module `wrapWasi(...).wasiImport` too if it decompresses.)
//
//   wasm_host.http_request(req_off i32, req_len i32, res_off i32, res_cap i32) -> i32
//     req: the request text of "wasm-fetch 1" (src/downloads.jl), res: the response text
//     written back; returns its length (or -length when res_cap is too small: nothing
//     written). Suspending (JSPI): the export must be called through WebAssembly.promising.
import { parseRequest, formatResult } from '../common/fetch.mjs';
import { makeMapper } from './paths.mjs';
import { perform } from './http.mjs';

export function makeImports({ preopens = {}, fetchImpl } = {}) {
  const map = makeMapper(preopens);
  let memory = null;
  const stats = { requests: 0 };
  async function http_request(reqOff, reqLen, resOff, resCap) {
    let result;
    try {
      const req = parseRequest(new TextDecoder().decode(new Uint8Array(memory.buffer, reqOff, reqLen)));
      req.outputHost = req.output ? map.toHost(req.output) : '';
      req.inputHost = req.input ? map.toHost(req.input) : '';
      stats.requests++;
      result = await perform(req, { fetchImpl });
    } catch (err) {
      result = { code: 2, message: String(err?.message ?? err), url: '', status: 0, headers: [] };
    }
    const bytes = new TextEncoder().encode(formatResult(result));
    if (bytes.length > resCap) return -bytes.length;
    new Uint8Array(memory.buffer, resOff, bytes.length).set(bytes);   // (a fresh view: memory may have grown)
    return bytes.length;
  }
  return { imports: { wasm_host: { http_request: new WebAssembly.Suspending(http_request) } },
           bindMemory(m) { memory = m; }, stats };
}
