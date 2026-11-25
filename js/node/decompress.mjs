// WasmHost's decompression on Node: one request of protocol "wasm-decompress 1" done with
// node:zlib. gzip and deflate (zlib format) on every supported Node; zstd where node:zlib has
// it.
import fs from 'node:fs';
import zlib from 'node:zlib';
import { pipeline } from 'node:stream/promises';
import { ERRNO, chooseFormat } from '../common/decompress.mjs';

export const hasZstd = typeof zlib.createZstdDecompress === 'function';

// the WASI errno of a Node error
export function errnoOf(err) {
  if (err?.code === 'ENOENT') return ERRNO.ENOENT;
  if (err?.code === 'EACCES' || err?.code === 'EPERM') return ERRNO.EACCES;
  return ERRNO.EIO;
}

function stage(format) {
  if (format === 'gzip') return zlib.createGunzip();
  if (format === 'deflate') return zlib.createInflate();
  return zlib.createZstdDecompress();
}

// Decompress the host file `srcHost` into `dstHost`: [errno, message], [0, ''] when done. A
// failure removes `dstHost` only once this call has opened it for writing: before that (no
// source, not the format's data, a destination that can't be opened, or that is the source
// itself, by another name too: EINVAL) a file of that name is left as it is. And only if the
// name is still that file's: one renamed away meanwhile keeps its new name, and the file that
// took the old one stays. (Checked, then removed, by name: a rename between the two is not
// seen.)
export async function decompressFile(srcHost, dstHost, format = 'auto') {
  let head;
  try {
    const fd = fs.openSync(srcHost, 'r');
    try {
      // (opening the destination would truncate the source)
      const s = fs.fstatSync(fd, { bigint: true }), d = fs.statSync(dstHost, { bigint: true, throwIfNoEntry: false });
      if (d !== undefined && d.dev === s.dev && d.ino === s.ino) return [ERRNO.EINVAL, 'the source and the destination are the same file'];
      head = Buffer.alloc(6);
      head = head.subarray(0, fs.readSync(fd, head, 0, 6, 0));
    } finally { fs.closeSync(fd); }
  } catch (err) {
    return [errnoOf(err), String(err?.message ?? err)];
  }
  const c = chooseFormat(format, head);
  if (c.errno !== undefined) return [c.errno, c.message];
  if (c.format === 'zstd' && !hasZstd) return [ERRNO.ENOSYS, `zstd: this Node (${process.version}) has no zlib.createZstdDecompress`];
  // (the stream opens the destination, off this thread: a FIFO waits there for its reader)
  const out = fs.createWriteStream(dstHost);
  let opened;   // the file opened, by device and inode
  out.once('open', (fd) => { try { opened = fs.fstatSync(fd, { bigint: true }); } catch {} });
  try {
    await pipeline(fs.createReadStream(srcHost), stage(c.format), out);
    return [0, ''];
  } catch (err) {
    const now = opened && fs.statSync(dstHost, { bigint: true, throwIfNoEntry: false });
    if (now && now.dev === opened.dev && now.ino === opened.ino) fs.rmSync(dstHost, { force: true });
    return [errnoOf(err), `${c.format}: ${String(err?.message ?? err)}`];
  }
}
