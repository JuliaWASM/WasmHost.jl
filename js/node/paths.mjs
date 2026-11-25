// Guest (WASI) paths of the module to the host's, through the preopens given to node:wasi.
import fs from 'node:fs';
import path from 'node:path';

// The host path `p` (absolute) names once its symbolic links are followed, one component at a
// time as the kernel does: a link's target from the link's directory, a dangling link's too
// (creating a file through it makes the target). Components after the first that doesn't exist
// are taken as they are.
function resolveLinks(p) {
  let done = path.parse(p).root;
  const todo = p.slice(done.length).split(path.sep);
  let missing = false;
  for (let links = 0; todo.length > 0;) {
    const c = todo.shift();
    if (c === '' || c === '.') continue;
    if (c === '..') { done = path.dirname(done); continue; }
    const next = path.join(done, c);
    let st = null;
    if (!missing) {
      try { st = fs.lstatSync(next); } catch (err) { if (err?.code !== 'ENOENT') throw err; missing = true; }
    }
    if (st?.isSymbolicLink()) {
      if (++links > 40) throw Object.assign(new Error(`wasmhost: too many symbolic links in ${p}`), { code: 'ELOOP' });
      const target = fs.readlinkSync(next);
      if (path.isAbsolute(target)) done = path.parse(target).root;
      todo.unshift(...target.slice(path.isAbsolute(target) ? done.length : 0).split(path.sep));
    } else {
      done = next;
    }
  }
  return done;
}

export function makeMapper(preopens) {
  const entries = Object.entries(preopens).map(([g, h]) => [path.posix.normalize(g), h]);
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
      if (!best) throw Object.assign(new Error(`wasmhost: ${guest} is outside the preopens`), { code: 'EACCES' });
      const root = resolveLinks(path.resolve(best[1]));
      const host = resolveLinks(path.join(root, path.posix.relative(best[0], g)));
      if (host !== root && !host.startsWith(root.endsWith(path.sep) ? root : root + path.sep))
        throw Object.assign(new Error(`wasmhost: ${guest} is outside the preopens (through a symbolic link)`), { code: 'EACCES' });
      return host;
    },
  };
}
