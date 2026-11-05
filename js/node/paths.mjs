// Guest (WASI) paths of the module to the host's, through the preopens given to node:wasi.
import path from 'node:path';

export function makeMapper(preopens) {
  const entries = Object.entries(preopens).map(([g, h]) => [path.posix.normalize(g), h]);
  return {
    // fd -> guest path of a preopen (node:wasi numbers them from 3 in order)
    preopenOf: (fd) => entries[fd - 3]?.[0],
    // a guest path -> the host's, through the longest preopen containing it
    toHost(guest) {
      const g = path.posix.normalize(guest);
      let best = null;
      for (const [gp, hp] of entries)
        if ((g === gp || g.startsWith(gp.endsWith('/') ? gp : gp + '/')) && (!best || gp.length > best[0].length))
          best = [gp, hp];
      if (!best) throw Object.assign(new Error(`wasmhost: ${guest} is outside the preopens`), { code: 'EACCES' });
      return path.join(best[1], path.posix.relative(best[0], g));
    },
  };
}
