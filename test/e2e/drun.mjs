// node | bun   drun.mjs MODULE.wasm MODE(jspi|sync) WORKDIR INDIR
// Runs dprog.jl's module on Node's WASI with WasmHost's spool adapter: the compressed artifacts
// of INDIR (copied to WORKDIR/in), decompressed into WORKDIR/out. The platform tags are
// E2E_PLATFORM (the harness passes the same to the native run), or detected. (The module's regex
// engine was WasmCodegen's `julia_regex` host extension, since removed: whatever replaces it in
// build.jl needs its imports given here.)
import fs from 'node:fs';
import path from 'node:path';
import { WASI } from 'node:wasi';
import { wasiImportObject, wasiInitialize, jspiGap } from '../../js/node/wasi.mjs';
import { wrapWasi } from '../../js/node/spool.mjs';
import { platformEnv, PLATFORM_VAR } from '../../js/node/platform.mjs';

const [wasmPath, mode, work, indir] = process.argv.slice(2);
if (mode === 'jspi' && jspiGap()) { console.log(`SKIP: ${jspiGap()}`); process.exit(77); }
fs.rmSync(work, { recursive: true, force: true });
fs.mkdirSync(path.join(work, 'out'), { recursive: true });
fs.cpSync(indir, path.join(work, 'in'), { recursive: true });

const preopens = { [work]: work };
const env = { DPROG_IN: path.join(work, 'in'), DPROG_OUT: path.join(work, 'out'), PWD: work,
              WASMHOST_SPOOL: path.join(work, '.wasmhost'), E2E_OLD_PLATFORM: 'arch=i686;os=windows',
              ...(process.env.E2E_PLATFORM ? { [PLATFORM_VAR]: process.env.E2E_PLATFORM } : platformEnv({ cuda: 'none' })) };
const wasi = new WASI({ version: 'preview1', args: ['dprog'], env, preopens, returnOnExit: true });
const imports = wasiImportObject(wasi);
const host = wrapWasi(imports.wasi_snapshot_preview1, { preopens, spool: env.WASMHOST_SPOOL, mode });
const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
console.error('imports:', [...new Set(WebAssembly.Module.imports(mod).map((i) => i.module))].join(', '));
const inst = await WebAssembly.instantiate(mod, { ...imports, wasi_snapshot_preview1: host.wasiImport });
host.bindMemory(inst.exports.memory);
wasiInitialize(wasi, inst);
const t0 = performance.now();
const rc = mode === 'jspi' ? await WebAssembly.promising(inst.exports.main)() : inst.exports.main();
console.error(`main returned ${rc} in ${(performance.now() - t0).toFixed(0)} ms; host decompressions: ${host.stats.decompress}`);
console.error('spool files left:', fs.readdirSync(env.WASMHOST_SPOOL).length);
