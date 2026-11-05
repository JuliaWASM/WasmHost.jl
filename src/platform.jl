"""
    WasmHost.Platform

The host's platform tags, passed in the WASI environment as `WASMHOST_PLATFORM="k=v;k=v;..."`
(e.g. `arch=x86_64;os=linux;libc=glibc`), which the host adapter sets (`js/node/platform.mjs`).
A module compiled for Wasm has no platform of its own to detect; a program that picks
binaries for the machine it runs on (as Pkg does for artifacts) asks the host instead.

- [`tags`](@ref): the tags, as given;
- [`host_platform`](@ref): a `Base.BinaryPlatforms.Platform` of them, as `HostPlatform()` is
  natively, with this program's Julia version.

A program that used another variable before passes it in `names`:
`host_platform(names = ("WASMHOST_PLATFORM", "OLD_NAME"))`; the first one set wins.
"""
module Platform

import Base.BinaryPlatforms

const NAMES = ("WASMHOST_PLATFORM",)

# (a literal: printing a VersionNumber in the module is avoided)
const JULIA_VERSION = string(VERSION)

"""
    parse_tags(s) -> Vector{Pair{String,String}}

The tags of `"k=v;k=v;..."`, in order; empty entries are skipped. Throws an `ArgumentError`
for an entry without `=`.
"""
function parse_tags(s::String)::Vector{Pair{String,String}}
    tags = Pair{String,String}[]
    for kv in eachsplit(s, ';')
        isempty(kv) && continue
        i = findfirst(==('='), kv)
        i === nothing && throw(ArgumentError(string("host platform: a tag without `=`: ", kv)))
        push!(tags, String(SubString(kv, 1, prevind(kv, i))) => String(SubString(kv, nextind(kv, i))))
    end
    return tags
end

"""
    tags(; names = ("WASMHOST_PLATFORM",)) -> Union{Nothing, Vector{Pair{String,String}}}

The host's platform tags from the first of the environment variables `names` that is set, or
`nothing` when none is.
"""
function tags(; names::Tuple{Vararg{String}} = NAMES)::Union{Nothing,Vector{Pair{String,String}}}
    for n in names
        s = get(ENV, n, nothing)
        s === nothing || return parse_tags(s)
    end
    return nothing
end

"""
    host_platform(; names = ("WASMHOST_PLATFORM",)) -> Union{Nothing, Base.BinaryPlatforms.Platform}

The host's platform (see [`tags`](@ref)) with this program's `julia_version`, made a host
platform as `Base.BinaryPlatforms.HostPlatform()` makes the native one. `nothing` when the host
gave no tags. Throws an `ArgumentError` for tags without `arch` or `os`, or with a keyword of
the `Platform` constructor (`validate_strict`, `compare_strategies`).
"""
function host_platform(; names::Tuple{Vararg{String}} = NAMES)::Union{Nothing,BinaryPlatforms.Platform}
    t = tags(; names)
    t === nothing && return nothing
    return BinaryPlatforms.HostPlatform(platform_from_tags(t, JULIA_VERSION))
end

"""
    platform_from_tags(tags, julia_version) -> Base.BinaryPlatforms.Platform

`Platform(arch, os; tags..., julia_version)` (a `julia_version` tag in `tags` is ignored),
built without a keyword splat, which a trimmed program can't compile. The tags the constructor
normalizes as versions (`libgfortran_version`, `libstdcxx_version`, `os_version`) are set after
it, as the constructor stores them, when they are plain (one to three decimal components);
others go through the constructor.
"""
function platform_from_tags(tags::Vector{Pair{String,String}}, julia_version::String)::BinaryPlatforms.Platform
    arch = os = ""
    d = Dict{String,Any}()
    later = Pair{String,String}[]
    for (k, v) in tags
        k = lowercase(k)
        if k == "arch"
            arch = v
        elseif k == "os"
            os = v
        elseif k == "julia_version"
            # (the program's own is used)
        elseif k in ("validate_strict", "compare_strategies")
            throw(ArgumentError(string("host platform: ", k, " is not a platform tag")))
        elseif k in ("libgfortran_version", "libstdcxx_version", "os_version")
            n = plain_version(v)
            n === nothing ? (d[k] = v) : push!(later, k => n)
        else
            d[k] = v
        end
    end
    (isempty(arch) || isempty(os)) && throw(ArgumentError("host platform: the host gave no arch or os"))
    d["julia_version"] = julia_version
    p = BinaryPlatforms.Platform(arch, os, d)
    for (k, n) in later
        p[k] = n
    end
    return p
end

# "a", "a.b" or "a.b.c" (decimal) as `string(VersionNumber(v))` gives it ("a.b.c", without
# leading zeros), or `nothing`
function plain_version(v::String)::Union{Nothing,String}
    parts = split(v, '.')
    1 <= length(parts) <= 3 || return nothing
    n = UInt32[0, 0, 0]
    for (i, p) in enumerate(parts)
        (!isempty(p) && all(isdigit, p) && sizeof(p) <= 9) || return nothing
        n[i] = parse(UInt32, p)
    end
    return string(n[1], '.', n[2], '.', n[3])
end

end # module Platform
