// WasmHost's downloads on Node: one request of protocol "wasm-fetch 1" performed with `fetch`,
// the body streamed to or from files of the host.
import fs from 'node:fs';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { curlCode } from '../common/fetch.mjs';

// A request's timeout in milliseconds: the whole number that Julia's side made its seconds from
// (as libcurl gets them; 0 is none, Infinity too)
// (Rounded: a thousand times the seconds is not always that whole number, 8.124 * 1000, and
// `AbortSignal.timeout` refuses a fraction. An adapter from before this rounding fails such a
// request of a module built with this version: the adapter goes with the module.)
export const timeoutMs = (req) => Math.round(req.timeout * 1000);

// Perform one request (`req` of parseRequest, with `outputHost`/`inputHost` mapped): the result
// for formatResult.
export async function perform(req, { fetchImpl = globalThis.fetch } = {}) {
  try {
    const init = { method: req.method, headers: req.headers, redirect: 'follow' };
    // (beyond a timer's range, 2^31 - 1 ms, there is no timeout either: a timer would fire after
    // 1 ms instead)
    const ms = timeoutMs(req);
    if (ms > 0 && ms <= 0x7fffffff) init.signal = AbortSignal.timeout(ms);
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
