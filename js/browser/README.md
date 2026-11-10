# `@wasmhost/browser`: browser adapter (design, not implemented)

Nothing here has run in a browser yet: don't treat browsers as supported. `package.json` names
the future package; it isn't published. It must not import any `node:` module.

## Page messages

`page.mjs` is `common/page.mjs` (`WasmHost.Page`, the import library `wasm_host_page`). It needs
only the module's memory: no filesystem, no JSPI. It is tested in Node and Bun (`test/e2e`,
`prun.mjs`), not in a browser.

## Downloads

- **The import transport is the intended default.** A browser has `fetch` but usually no
  filesystem under the module.
  - `wasm_host.http_request` is a `WebAssembly.Suspending` around `fetch`.
  - The export is called through `WebAssembly.promising`.
  - Needs JSPI (Chromium-based browsers ship it; check others).
- **Bodies are the open question.** Protocol `wasm-fetch 1` passes request and response bodies as paths of
  the module's filesystem. In a browser that is either:
  - **(a)** a JavaScript WASI filesystem under the module (an in-memory preopen), which the
    adapter writes the body into; or
  - **(b)** a protocol 2 that moves bodies through the linear memory: e.g.
    `wasm_host.body_read(handle, buf, cap)`, and `body_write` for uploads.

  (b) needs no filesystem and is the better fit for browsers.
- **The spool transport** works only with (a), by wrapping that filesystem's `path_open` as
  `node/spool.mjs` does. It isn't the default.
- **Sync mode** is possible only inside a Worker. It needs `SharedArrayBuffer`, i.e. a
  cross-origin-isolated page (COOP/COEP headers), and a second worker to run `fetch` while the
  first blocks in `Atomics.wait`. A page's main thread may not block.
- **Browser `fetch` differs from Node's:**
  - CORS applies;
  - `Accept-Encoding`, `Cookie` and some other headers are forbidden and dropped;
  - redirects to other origins follow CORS;
  - `Response.url` is the final URL.

  Map CORS and network failures to libcurl's code 7.

## Decompression

- `DecompressionStream('gzip')` and `DecompressionStream('deflate')` (the zlib format, as
  `WasmHost.Decompress`'s `:deflate`). Browsers have no zstd: answer `ENOSYS` (52) for it, and
  have Pkg-like clients ask servers for gzip.
- Like bodies, the source and destination are files: this needs (a), or a protocol that moves
  the data through the linear memory.

## Platform

A page has no platform tags of its own to detect for binaries: `WASMHOST_PLATFORM` is
whatever the page sets in the WASI environment, if anything.

## Testing

A headless Chromium (e.g. Playwright's) running the e2e programs with the import transport
and (a) or (b) is the first milestone before any support claim.
