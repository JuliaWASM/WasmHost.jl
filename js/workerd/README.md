# workerd (notes, untested)

- WasmCodegen's `js/julia.mjs` provides WASI functions for workerd, but with no filesystem, so
  the spool transport doesn't apply.
- The import transport fits: `fetch` is native to workerd. The open questions are JSPI
  (`WebAssembly.Suspending`) and the body question of the browser notes (`../browser/`).
  Neither has been verified.
- Decompression: `DecompressionStream` (gzip, deflate), no zstd; the data would have to move
  through the linear memory, since there is no filesystem.
- `Atomics.wait` (sync mode) isn't expected to be available.
