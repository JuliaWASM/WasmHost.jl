// The protocol of WasmHost's decompression ("wasm-decompress 1", see src/decompress.jl): the
// host-independent part of every adapter. No Node or browser API is used here.

export const DPROTOCOL = 'wasm-decompress 1';

// the WASI errno values of an answer
export const ERRNO = { OK: 0, EACCES: 2, EILSEQ: 25, EIO: 29, ENOENT: 44, ENOSYS: 52 };

export const FORMATS = ['auto', 'gzip', 'deflate', 'zstd'];

export function parseDecompressRequest(text) {
  const lines = text.split('\n');
  if (lines[0] !== DPROTOCOL) throw new Error('wasm-decompress: not a request of ' + DPROTOCOL);
  const [, src, dst, format = ''] = lines;
  return { src, dst, format: format === '' ? 'auto' : format };
}

export function formatDecompressAnswer(errno, message = '') {
  return `${DPROTOCOL}\n${errno}\n${String(message).replace(/[\r\n]+/g, ' ')}\n`;
}

// The format of the first bytes of a file, by magic bytes: the formats of Pkg's
// `detect_archive_format` (gzip, zstd, bzip2, xz, lz4), or null.
export function detectFormat(b) {
  const at = (...m) => b.length >= m.length && m.every((x, i) => b[i] === x);
  if (at(0x28, 0xb5, 0x2f, 0xfd)) return 'zstd';
  if (at(0x1f, 0x8b)) return 'gzip';
  if (at(0x42, 0x5a, 0x68)) return 'bzip2';
  if (at(0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00)) return 'xz';
  if (at(0x04, 0x22, 0x4d, 0x18)) return 'lz4';
  return null;
}

// a zlib (RFC 1950) header: deflate, a window of at most 32 KiB, a valid check
export function isZlibHeader(b) {
  return b.length >= 2 && (b[0] & 0x0f) === 8 && (b[0] >> 4) <= 7 && ((b[0] << 8) | b[1]) % 31 === 0;
}

// Which decompressor to run for a request's `format` and the source's first bytes, or the
// errno and message of the refusal: { format } or { errno, message }.
export function chooseFormat(format, head) {
  if (!FORMATS.includes(format)) return { errno: ERRNO.EILSEQ, message: `unknown format ${JSON.stringify(format)}` };
  const found = detectFormat(head);
  if (format === 'auto') {
    if (found === 'gzip' || found === 'zstd') return { format: found };
    if (found !== null) return { errno: ERRNO.ENOSYS, message: `${found}: not supported by this host` };
    return { errno: ERRNO.EILSEQ, message: 'unrecognized compression format' };
  }
  if (format === 'deflate') return isZlibHeader(head) ? { format } : { errno: ERRNO.EILSEQ, message: 'not deflate (zlib) data' };
  return found === format ? { format } : { errno: ERRNO.EILSEQ, message: `not ${format} data` };
}
