# Browser adapter (design, not implemented)

Nothing here has run in a browser yet: don't treat browsers as supported.

- **Transport B (import library) is the intended default.** A browser has `fetch` but usually no
  filesystem under the module.
  - `wasm_fetch.request` is a `WebAssembly.Suspending` around `fetch`.
  - The export is called through `WebAssembly.promising`.
  - Needs JSPI (Chromium-based browsers ship it; check others).
- **Bodies are the open question.** Protocol 1 passes request and response bodies as paths of
  the module's filesystem. In a browser that is either:
  - **(a)** a JavaScript WASI filesystem under the module (an in-memory preopen), which the
    adapter writes the body into; or
  - **(b)** a protocol 2 that moves bodies through the linear memory: e.g.
    `wasm_fetch.body_read(handle, buf, cap)`, and `body_write` for uploads.

  (b) needs no filesystem and is the better fit for browsers.
- **Transport A (spool)** works only with (a), by wrapping that filesystem's `path_open` as
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
- **Testing:** a headless Chromium (e.g. Playwright's) running the e2e program with transport B
  and (a) or (b) is the first milestone before any support claim.
