// Guest (WASI) paths of the module to the host's, through the preopens given to node:wasi.
import fs from 'node:fs';
import path from 'node:path';

const fail = (code, message) => Object.assign(new Error(`wasmhost: ${message}`), { code });

// The host path `p` (absolute) names once its symbolic links are followed, one component at a
// time as the kernel does: a link's target from the link's directory, a dangling link's too
// (creating a file through it makes the target). What isn't a directory has no components after
// it, a trailing slash included (ENOTDIR). After a component that doesn't exist only names are
// taken, as they are (for a file or directories to be made): a `..` there is ENOENT.
function resolveLinks(p) {
  let done = path.parse(p).root;
  const todo = p.slice(done.length).split(path.sep);
  let missing = false;
  for (let links = 0; todo.length > 0;) {
    const c = todo.shift();
    if (c === '' || c === '.') continue;
    if (c === '..') {
      if (missing) throw fail('ENOENT', `no such file or directory: ${p}`);
      done = path.dirname(done);
      continue;
    }
    const next = path.join(done, c);
    let st = null;
    if (!missing) {
      try { st = fs.lstatSync(next); } catch (err) { if (err?.code !== 'ENOENT') throw err; missing = true; }
    }
    if (st?.isSymbolicLink()) {
      if (++links > 40) throw fail('ELOOP', `too many symbolic links in ${p}`);
      const target = fs.readlinkSync(next);
      if (path.isAbsolute(target)) done = path.parse(target).root;
      todo.unshift(...target.slice(path.isAbsolute(target) ? done.length : 0).split(path.sep));
    } else {
      if (st && !st.isDirectory() && todo.length > 0) throw fail('ENOTDIR', `not a directory: ${next}`);
      done = next;
    }
  }
  return done;
}

// A guest directory's path as the adapter compares it: normalized, without a trailing slash
// (`/work/` is `/work`).
export const guestDir = (g) => path.posix.normalize(g).replace(/(?<=.)\/$/, '');

// `preopens` as given to node:wasi. Each host directory is resolved here, once, as WASI opens
// it once: a later change of the working directory, or of a link on the way to it, doesn't move
// the preopen.
export function makeMapper(preopens) {
  const entries = Object.entries(preopens).map(([g, h]) => [guestDir(g), resolveLinks(path.resolve(h))]);
  return {
    // fd -> guest path of a preopen (node:wasi numbers them from 3 in order)
    preopenOf: (fd) => entries[fd - 3]?.[0],
    // a guest path -> the host's, through the longest preopen containing it. The host path has
    // its symbolic links followed, and is still inside the preopen's directory: a link of the
    // tree that leads out of it is refused, as a `..` is. (By name, as Node has no `openat`: a
    // directory replaced with a link between this check and the use of the path is followed.)
    toHost(guest) {
      const g = path.posix.normalize(guest);
      let best = null;
      for (const [gp, hp] of entries)
        if ((g === gp || g.startsWith(gp.endsWith('/') ? gp : gp + '/')) && (!best || gp.length > best[0].length))
          best = [gp, hp];
      if (!best) throw fail('EACCES', `${guest} is outside the preopens`);
      const [, root] = best;
      // (the rest of `g` as it is: a trailing slash counts)
      const host = resolveLinks(path.join(root, g.slice(best[0].length)));
      if (host !== root && !host.startsWith(root.endsWith(path.sep) ? root : root + path.sep))
        throw fail('EACCES', `${guest} is outside the preopens (through a symbolic link)`);
      return host;
    },
  };
}
