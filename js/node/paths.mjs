// Guest (WASI) paths of the module to the host's, through the preopens given to node:wasi and
// as node:wasi (uvwasi's path_resolver.c) takes them: the module then gets the file it would
// open itself.
import fs from 'node:fs';
import path from 'node:path';

const fail = (code, message) => Object.assign(new Error(`wasmhost: ${message}`), { code });
// (`outside`: refused for where it leads, not for what the file system said of it)
const outside = (guest, how = '') => Object.assign(fail('EACCES', `${guest} is outside the preopens${how}`), { outside: true });
const within = (p, dir, sep) => p === dir || p.startsWith(dir.endsWith(sep) ? dir : dir + sep);

// uvwasi's limit (UVWASI__MAX_SYMLINK_FOLLOWS)
const MAX_FOLLOWS = 32;
// the kernel's (libuv's `uv_fs_realpath`, which uvwasi calls for a preopen): `fs.realpathSync`
// itself takes the `..` out of the path before it looks at any link
const realpath = fs.realpathSync.native;

// The host path `p` (absolute; its last component not a link, unless a slash follows it) with
// the links on the way followed, by the kernel (`realpath`; its errors are the answer). Names
// after the last directory that exists stay as they are (a file or directories to be made),
// the trailing slash too: the kernel doesn't make a regular file of `name/`. (The host's
// separator only: on POSIX a `\` is a character of a name.)
function physical(p) {
  const names = [];
  let dir = p;
  while (dir.endsWith(path.sep) && path.dirname(dir) !== dir) dir = dir.slice(0, -1);
  for (; ; dir = path.dirname(dir)) {
    try {
      const real = path.join(realpath(dir), ...names);
      return names.length > 0 && p.endsWith(path.sep) ? real + path.sep : real;
    } catch (err) {
      if (err?.code !== 'ENOENT') throw err;
    }
    // (a dangling link is no directory to make things in)
    if (fs.lstatSync(dir, { throwIfNoEntry: false })) throw fail('ENOENT', `no such file or directory: ${p}`);
    names.unshift(path.basename(dir));
  }
}

// A guest directory's path as the adapter compares it: normalized, without a trailing slash
// (`/work/` is `/work`).
export const guestDir = (g) => path.posix.normalize(g).replace(/(?<=.)\/$/, '');

// `preopens` as given to node:wasi. Each host directory is resolved here, once, as WASI opens
// it once (and as it does, with `realpath`: `link/..` is the parent of the link's target): a
// later change of the working directory, or of a link on the way to it, doesn't move the
// preopen.
export function makeMapper(preopens) {
  const entries = Object.entries(preopens).map(([g, h]) => [guestDir(g), realpath(h)]);
  return {
    // fd -> guest path of a preopen (node:wasi numbers them from 3 in order)
    preopenOf: (fd) => entries[fd - 3]?.[0],
    // a guest path -> the host's, through the longest preopen containing it. As uvwasi does it:
    // - `.` and `..` are taken out of the guest path as text, before any file is looked at
    //   (`link/..` is the link's directory, `absent/..` the directory it would be in);
    // - a link as the last component is followed here, its target as text too: joined to the
    //   link's guest directory, or, absolute, a guest path. It must stay inside the preopen;
    // - links in the directories before it are the kernel's to follow.
    // uvwasi lets those last ones lead anywhere. Here the path the kernel arrives at must
    // still be inside the preopen's directory: a link of the tree that leads out of it is
    // refused, as a `..` is. (By name, as Node has no `openat`: a directory replaced with a
    // link between this check and the use of the path is followed. And as a string: a link
    // whose target isn't UTF-8 is not followed to the file the kernel would reach.)
    toHost(guest) {
      let g = path.posix.normalize(guest);
      let best = null;
      for (const entry of entries)
        if (within(g, entry[0], '/') && (!best || entry[0].length > best[0].length)) best = entry;
      if (!best) throw outside(guest);
      const [gp, root] = best;
      let host;
      for (let follows = 0; ;) {
        if (!within(g, gp, '/')) throw outside(guest, ' (through a symbolic link)');
        // (the rest of `g` as it is: a trailing slash counts)
        host = path.join(root, g.slice(gp.length));
        let target;
        try { target = fs.readlinkSync(host); } catch (err) {
          // (not a link, or nothing: both are fine)
          if (err?.code === 'EINVAL' || err?.code === 'ENOENT') break;
          throw err;
        }
        if (++follows >= MAX_FOLLOWS) throw fail('ELOOP', `too many symbolic links in ${guest}`);
        g = path.posix.normalize(target.startsWith('/') ? target : `${g}/../${target}`);
      }
      const real = physical(host);
      if (!within(real, root, path.sep)) throw outside(guest, ' (through a symbolic link)');
      return real;
    },
  };
}
