// The host's platform tags for WasmHost.Platform (see src/platform.jl): merged, checked as
// Base.BinaryPlatforms checks them, and written as WASMHOST_PLATFORM = "k=v;k=v;...". No Node or
// browser API is used here.

export const PLATFORM_VAR = 'WASMHOST_PLATFORM';

// (BinaryPlatforms' `add_tag!` refuses these characters in a lower-cased name or value)
const TAG_NONOS = `+- /<>:"'\\|?*`;
// (keywords of the Platform constructor, not tags)
const NOT_TAGS = new Set(['validate_strict', 'compare_strategies']);

// The detected tags (pairs), then `overrides` (an object) key by key: a detected key keeps its
// position, a new key is appended. Keys are lower-cased, as BinaryPlatforms stores them.
// `julia_version` is dropped: the module adds its own.
export function mergeTags(detected, overrides = {}) {
  if (overrides === null || typeof overrides !== 'object' || Array.isArray(overrides))
    throw new Error('wasmhost: platform overrides must be an object of string tags');
  const tags = detected.filter(([k]) => k !== 'julia_version').map(([k, v]) => [k, v]);
  for (const [k0, v] of Object.entries(overrides)) {
    const k = k0.toLowerCase();
    if (k === 'julia_version') continue;
    if (typeof v !== 'string') throw new Error(`wasmhost: platform tag ${JSON.stringify(k0)} must be a string, not ${typeof v}`);
    if (k === '' || NOT_TAGS.has(k)) throw new Error(`wasmhost: ${JSON.stringify(k0)} is not a platform tag name`);
    for (const [what, x] of [['name', k], ['value', v.toLowerCase()]])
      if ([...TAG_NONOS].some((c) => x.includes(c)))
        throw new Error(`wasmhost: invalid character in platform tag ${what} ${JSON.stringify(what === 'name' ? k0 : v)} (BinaryPlatforms refuses any of ${TAG_NONOS})`);
    const i = tags.findIndex(([q]) => q === k);
    if (i >= 0) tags[i][1] = v; else tags.push([k, v]);
  }
  return tags;
}

// "k=v;k=v;..." of the tags; `;` (and `=` in a name) would be ambiguous
export function formatTags(tags) {
  for (const [k, v] of tags)
    if (k.includes(';') || k.includes('=') || v.includes(';'))
      throw new Error(`wasmhost: platform tag ${JSON.stringify(k)}=${JSON.stringify(v)}: ';' (or '=' in a name) cannot be passed in ${PLATFORM_VAR}`);
  return tags.map(([k, v]) => `${k}=${v}`).join(';');
}
