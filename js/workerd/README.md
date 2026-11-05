# workerd (notes, untested)

- WasmCodegen's `js/julia.mjs` provides WASI functions for workerd, but with no filesystem, so
  transport A doesn't apply.
- Transport B fits: `fetch` is native to workerd. The open questions are JSPI
  (`WebAssembly.Suspending`) and the body question of the browser notes (`../browser/`).
  Neither has been verified.
- `Atomics.wait` (sync mode) isn't expected to be available.
