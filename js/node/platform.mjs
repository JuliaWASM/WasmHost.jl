// The host's platform tags on Node, for WasmHost.Platform: detected arch, os and (Linux) libc,
// then overrides, as the WASI environment variable WASMHOST_PLATFORM.
import os from 'node:os';
import { PLATFORM_VAR, mergeTags, formatTags } from '../common/platform.mjs';

export { PLATFORM_VAR, mergeTags, formatTags };

const ARCH = { x64: 'x86_64', arm64: 'aarch64', ia32: 'i686', arm: 'armv7l', riscv64: 'riscv64' };
const OS = { linux: 'linux', darwin: 'macos', win32: 'windows', freebsd: 'freebsd' };

// The detected tags of this Node process: arch, os and (Linux) libc; a value Node can't map is
// absent. (`opts` stand in for the process, in tests; an explicit `glibc: undefined` is musl.)
export function detectPlatform(opts = {}) {
  const arch = opts.arch ?? process.arch, platform = opts.platform ?? process.platform;
  const endianness = opts.endianness ?? os.endianness();
  const glibc = 'glibc' in opts ? opts.glibc : process.report.getReport().header.glibcVersionRuntime;
  const tags = [];
  const a = arch === 'ppc64' ? (endianness === 'LE' ? 'powerpc64le' : undefined) : ARCH[arch];
  if (a) tags.push(['arch', a]);
  const o = OS[platform];
  if (o) tags.push(['os', o]);
  if (o === 'linux') tags.push(['libc', glibc ? 'glibc' : 'musl']);
  return tags;
}

// { WASMHOST_PLATFORM: "k=v;..." } for the WASI `env`: the detected tags with `overrides`
export function platformEnv(overrides = {}, detected = detectPlatform()) {
  return { [PLATFORM_VAR]: formatTags(mergeTags(detected, overrides)) };
}
