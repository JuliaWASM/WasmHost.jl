// The protocol of WasmFetch (version 1, see src/WasmFetch.jl) and libcurl's error codes: the
// host-independent part of every adapter. No Node or browser API is used here.

export const PROTOCOL = 'wasm-fetch 1';

// libcurl's error codes, which `Downloads.RequestError` carries
export const CURLE = { COULDNT_RESOLVE_HOST: 6, COULDNT_CONNECT: 7, WRITE_ERROR: 23, READ_ERROR: 26,
                OPERATION_TIMEDOUT: 28, TOO_MANY_REDIRECTS: 47, RECV_ERROR: 56, PEER_FAILED_VERIFICATION: 60 };

export function curlCode(err) {
  const c = err?.cause?.code ?? err?.code;
  if (err?.name === 'TimeoutError' || err?.name === 'AbortError') return CURLE.OPERATION_TIMEDOUT;
  if (c === 'ENOTFOUND' || c === 'EAI_AGAIN') return CURLE.COULDNT_RESOLVE_HOST;
  if (c === 'ECONNREFUSED' || c === 'EHOSTUNREACH' || c === 'ENETUNREACH') return CURLE.COULDNT_CONNECT;
  // (fetch refuses the ports of the Fetch standard's "bad port" list; libcurl would connect)
  if (/bad port/.test(err?.cause?.message ?? '')) return CURLE.COULDNT_CONNECT;
  if (typeof c === 'string' && /CERT|SSL|TLS/.test(c)) return CURLE.PEER_FAILED_VERIFICATION;
  if (/redirect count exceeded/i.test(err?.cause?.message ?? err?.message ?? '')) return CURLE.TOO_MANY_REDIRECTS;
  return CURLE.RECV_ERROR;
}

export function parseRequest(text) {
  const lines = text.split('\n');
  if (lines[0] !== PROTOCOL) throw new Error('wasm-fetch: not a request of ' + PROTOCOL);
  const [, method, url, output, input, timeout] = lines;
  const headers = [];
  for (const l of lines.slice(6)) {
    const i = l.indexOf(':');
    if (i > 0) headers.push([l.slice(0, i), l.slice(i + 1).trim()]);
  }
  return { method, url, output, input, timeout: timeout === 'inf' ? Infinity : Number(timeout), headers };
}

export function formatResult(r) {
  const hs = (r.headers ?? []).map(([k, v]) => `${k}: ${String(v).replace(/[\r\n]+/g, ' ')}`);
  return [PROTOCOL, r.code, (r.message ?? '').replace(/[\r\n]+/g, ' '), r.url, r.status, r.statusLine ?? '', ...hs].join('\n') + '\n';
}
