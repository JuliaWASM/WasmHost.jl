// node native.mjs WORKDIR : the same program natively (Downloads + libcurl) against server.mjs
import fs from 'node:fs'; import path from 'node:path'; import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
const work = process.argv[2];
fs.rmSync(work, { recursive: true, force: true }); fs.mkdirSync(path.join(work, 'out'), { recursive: true });
const server = spawn(process.execPath, [new URL('./server.mjs', import.meta.url).pathname, '0'], { stdio: ['ignore', 'pipe', 'inherit'] });
const port = await new Promise((res) => server.stdout.on('data', (d) => { const m = /listening (\d+)/.exec(String(d)); if (m) res(Number(m[1])); }));
try {
  const dir = path.dirname(new URL(import.meta.url).pathname);
  const r = spawnSync(process.env.JULIA, ['--startup-file=no', '--project=' + process.env.E2E_PROJECT, '-e',
    `include(${JSON.stringify(path.join(dir, 'prog.jl'))}); t = time(); FetchProg.main(); println(stderr, "main took ", round(Int, 1000(time() - t)), " ms (first call, includes compilation)")`],
    { env: { ...process.env, FETCH_BASE: `http://127.0.0.1:${port}`, FETCH_OUT: path.join(work, 'out') }, stdio: 'inherit' });
  const b = fs.readFileSync(path.join(work, 'out', 'blob.bin'));
  console.error(`native rc ${r.status}; blob.bin: ${b.length} bytes, sha256 ${crypto.createHash('sha256').update(b).digest('hex')}`);
} finally { server.kill(); }
