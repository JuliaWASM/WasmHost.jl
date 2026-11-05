# WasmFetch.jl

HTTP requests for Julia programs compiled to WebAssembly by
[WasmCodegen.jl](https://github.com/gbaraldi/WasmCodegen.jl), performed by the host's `fetch`.

With this package loaded next to Downloads and WasmCodegen, a program that calls
`Downloads.download` or `Downloads.request` compiles for WASI and downloads through the host,
whose `fetch` handles TLS, redirects and proxies. Natively nothing changes: Downloads still
uses libcurl. WasmCodegen itself carries no networking.

```julia
using Downloads
f() = String(take!(Downloads.download("https://example.org/data.csv", IOBuffer())))
```

**Status:** a first release. It is tested on **Node** with transport A (spool). Other hosts are
designed but untested; see [Hosts](#hosts).

## How it works

- **The rewrite (Julia, host-agnostic).** A package extension, `WasmFetchDownloadsExt`, is loaded
  when both Downloads and WasmCodegen are loaded. It adds methods to WasmCodegen's overlay method
  table `WasmCodegen.Runtime.WASM_METHODS` for `Downloads.request`, `Downloads.Curl.status_ok`
  and `Downloads.get_ca_roots`. WasmCodegen compiles them in place of the native methods, so the
  module contains no libcurl. `Downloads.download` is Downloads' own and calls `request`. The
  Julia side doesn't know which host it runs on; a build only chooses the transport.
- **The transports.** Both carry the same protocol, documented in `src/WasmFetch.jl`: a request
  to the host and its response back.
  - **A, spool (the default; works today).** Files of a spool directory inside a WASI preopen.
    The module writes `<spool>/<id>.req` and opens `<spool>/<id>.res`. The host adapter wraps
    the module's WASI `path_open`: opening a pending `.res` performs the request with `fetch`,
    streaming the body to the requested file, and writes the response first. The module
    imports only `wasi_snapshot_preview1`.
  - **B, import library (requires an upstream change under discussion).** A
    `wasm_fetch.request` import. It needs WasmCodegen to let a program declare an import
    library of its own, `Config(import_libraries = ["wasm_fetch"])`, which is proposed upstream
    in [gbaraldi/WasmCodegen.jl#57](https://github.com/gbaraldi/WasmCodegen.jl/pull/57) and not
    merged. It also uses WasmCodegen's staging area of the linear memory
    (`Runtime.Staging`) to pass the request and response text. It has been tested only against
    a local WasmCodegen build that has both.
- **Waiting.** `fetch` is asynchronous, and the adapter waits in one of two ways:
  - **`jspi`:** the intercepted `path_open`, or `wasm_fetch.request`, is a
    `WebAssembly.Suspending`, so the module is suspended while `fetch` runs. Call the export
    through `WebAssembly.promising`.
  - **`sync`:** the request runs on a worker thread while the main thread blocks in
    `Atomics.wait`. Node only, transport A only.

## Requirements

- Julia 1.12 or 1.13.
- A WasmCodegen with WASI support for `Config(host = :wasi)`: the filesystem and the environment
  (`ENV`). At the time of writing these are open pull requests on gbaraldi/WasmCodegen.jl, and
  upstream `main` doesn't have them yet.
- Node 22 or newer for the Node adapter, with JavaScript Promise Integration for the `jspi` mode
  (`--experimental-wasm-jspi` where it isn't on by default).

## Building

WasmCodegen isn't registered: add it, with its WasmBuilder and IRStructurizer, from source.

```julia
# build.jl, run with an environment that has WasmCodegen, Downloads and WasmFetch
using WasmCodegen, Downloads, WasmFetch     # loading all three loads the extension
include("myprogram.jl")                     # defines main()::Int32, which uses Downloads

c = WasmCodegen.compile([WasmCodegen.Entry(main, (); name = "main")];
                        config = WasmCodegen.Config(host = :wasi, verify = :warn))
write("main.wasm", c.bytes)
```

**`verify = :error` doesn't pass yet.** WasmCodegen's trim verifier checks the code native
inference produces. Native inference inlines Downloads' own `request(url)` before WasmCodegen's
overlay table is consulted, so the verifier reports errors in native code (libcurl's
`easy_hook`) that the module never compiles. The module itself is clean: 0 unsupported
constructs with `trim = :safe`. Use `verify = :warn` (the default) until WasmCodegen's verifier
checks overlaid methods.

**Transport B:** also define `WasmFetch.transport() = :import` before compiling, and pass
`import_libraries = ["wasm_fetch"]` to `Config`. `transport` is a function rather than a setting
read at run time, so that the module contains only the transport it uses.

## Running in Node (transport A)

```js
import { WASI } from 'node:wasi';
import fs from 'node:fs';
import { wrapWasi } from './WasmFetch.jl/js/node/spool.mjs';

const work = '/abs/work';                        // preopened at the same path
const spool = `${work}/.wasm-fetch`;             // the module finds it in ENV
const wasi = new WASI({ version: 'preview1', preopens: { [work]: work },
                        env: { WASM_FETCH_SPOOL: spool, PWD: work } });
const fetchHost = wrapWasi(wasi.wasiImport, { preopens: { [work]: work }, spool, mode: 'jspi' });

const inst = await WebAssembly.instantiate(new WebAssembly.Module(fs.readFileSync('main.wasm')),
                                           { wasi_snapshot_preview1: fetchHost.wasiImport });
fetchHost.bindMemory(inst.exports.memory);
wasi.initialize(inst);
await WebAssembly.promising(inst.exports.main)();   // mode 'sync': call inst.exports.main() directly
```

Without the adapter, or without `WASM_FETCH_SPOOL`, every request fails with a
`Downloads.RequestError` (code 2), as a program without libcurl would.

## Hosts

The JavaScript side has one adapter per host, under `js/`, sharing the host-independent protocol
in `js/common/`. See [`js/README.md`](js/README.md).

| Host | Transport A (spool) | Transport B (import) | Waiting | Tested? |
|---|---|---|---|---|
| **Node** 22+ (`node:wasi`) | `js/node/spool.mjs` | `js/node/imports.mjs` | JSPI; sync worker (A) | **Yes:** A in both modes; B only with a local WasmCodegen that has the upstream change |
| **Browsers** | Only on a JavaScript WASI filesystem | Intended default (`js/browser/`, not written) | JSPI where available; a sync worker only with cross-origin isolation | **No.** Design notes only: not supported until something has run in a browser |
| **workerd** | No filesystem | Fits | JSPI, if available | **No** (`js/workerd/`) |
| **wasmtime** | CLI: no (needs a helper process and polling) | From an embedding | the embedding's | **No** (`js/wasmtime/`) |

## What is supported (Node, transport A)

| | |
|---|---|
| **Methods and bodies** | GET, HEAD, PUT, POST and other methods. Bodies to a path, an `IO` or nowhere; request bodies from a path or an `IO`. A path body is streamed to the file by the host. |
| **Headers** | Request headers, including Downloads' default `User-Agent`. The response's headers with lower-case names, `set-cookie` entries kept apart. |
| **Redirects** | Followed. `Response.url` is the final URL. |
| **Errors** | A non-2xx `download` is a `RequestError` with code 0 and the response. A transport failure is a `RequestError` with libcurl's code (6 resolve, 7 connect, 28 timeout, 47 too many redirects, 60 TLS, else 56) and status 0. `request(throw = false)` returns it. |
| **Progress** | One call at the end with the complete transfer: `(Content-Length or 0, bytes received)`, as libcurl's last call. |
| **`Downloader`** | Accepted. Its `easy_hook` and the `verbose`, `debug` and `interrupt` options have no effect, since there is no libcurl. |

## Known differences from libcurl

- **Status line:** it is always `HTTP/1.1 <code> <text>`. `fetch` doesn't expose the HTTP
  version, so against an HTTP/2 server native Downloads says `HTTP/2 200`.
- **Error messages:** they are `fetch`'s, not curl's. The error codes are mapped to libcurl's.
- **Blocked ports:** `fetch` refuses the ports of the Fetch standard's "bad port" list (e.g. 9,
  25, 6000), which libcurl would connect to. These are reported as code 7.
- **Content-Encoding:** `fetch` decodes a compressed response (gzip, deflate, br and, in newer
  runtimes, zstd) itself, and browsers don't let a program set `Accept-Encoding`. libcurl, as
  Downloads uses it, writes the raw bytes.
- **Redirect limit:** `fetch`'s is 20, where Downloads asks libcurl for 50.
- **Waiting with Julia Tasks:** a request blocks the whole module: other Julia tasks don't run
  while it waits. Concurrent requests would need the host's event loop to wait on request
  handles.

## Internal APIs it relies on

- **`WasmCodegen.Runtime.WASM_METHODS`:** WasmCodegen's internal mechanism today, and how its
  own runtime replaces methods. (`@wasm_method` is `Base.Experimental.@overlay` on it.) It isn't
  yet a supported interface for packages; that is being asked upstream.
- **`WasmCodegen.Runtime.Staging`:** used by transport B only.

Expect to update this package when either changes.

## Tests

- `test/runtests.jl`: native tests of the protocol, including a round trip through the
  JavaScript protocol code when `node` is on `PATH`. Run them with `Pkg.test()`.
- `test/e2e/e2e.jl`: compiles `test/e2e/prog.jl` (plain Downloads calls: an `IOBuffer` body, a
  3 MiB file, a redirect with a custom header, HEAD, POST, a 404, a refused connection,
  `throw = false`, an explicit `Downloader`, progress) with WasmCodegen. It runs the module in
  Node against a local server and checks that its output and downloaded bytes equal the native
  program's.

  ```
  julia test/e2e/e2e.jl /path/to/WasmCodegen.jl [spool|import|all]
  ```

## License

MIT
