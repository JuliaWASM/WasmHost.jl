# wasmtime (notes, untested)

- **The wasmtime CLI can't wrap `path_open`,** so transport A works only with a helper process
  serving the spool directory. The module would then have to poll for the response, since
  nothing makes its `open` wait.
- **An embedding** (the wasmtime crate, wasmtime-py and so on) can define the `wasm_fetch`
  import module directly: transport B. The embedding then performs the request with its own
  HTTP client and writes the body where the request says.
- **WASI preview 2's `wasi:http`** is the standard answer for wasmtime, but it needs the
  component model, which WasmCodegen's core modules don't target. Out of scope.
