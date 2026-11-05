# Host adapters

The Julia side of WasmFetch is host-agnostic: the overlays and the protocol don't know which
runtime they run on. A build only chooses the **transport**:
- **A, spool:** files of a spool directory over the WASI filesystem.
- **B, import:** the import library `wasm_fetch`, which needs `Config(import_libraries)`, an
  upstream WasmCodegen change under discussion.

Each host has its own adapter here, sharing the host-independent protocol in `common/`.

| Directory | Host | Transports | Waiting | Status |
|---|---|---|---|---|
| `common/` | any | – | – | the protocol (parse a request, format a response) and libcurl's error codes; no host API |
| `node/` | Node 22+ (`node:wasi`) | A: `spool.mjs`; B: `imports.mjs` | JSPI (A, B); sync worker + `Atomics.wait` (A) | **tested** (end to end, output identical to native Downloads) |
| `browser/` | browsers | B planned; A only on a JavaScript WASI filesystem | JSPI where available; a sync worker only with cross-origin isolation | design notes, **not implemented, untested** |
| `workerd/` | Cloudflare workerd | B | JSPI if available | notes, untested |
| `wasmtime/` | wasmtime | B from an embedding | the embedding's | notes, untested |
