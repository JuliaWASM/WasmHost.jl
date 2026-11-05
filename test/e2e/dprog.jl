# The decompression end-to-end program: WasmHost.Decompress and WasmHost.Platform, as a program
# that unpacks artifacts for the machine it runs on would call them.
module DecompressProg
using WasmHost
using WasmHost.Decompress: decompress, DecompressError
import Base.BinaryPlatforms: arch, os, libc, triplet

say(xs...) = (println(Core.stdout, xs...); nothing)
indir() = get(ENV, "DPROG_IN", "/in")
outdir() = get(ENV, "DPROG_OUT", "/out")

function attempt(what::String, src::String, dst::String, format::Symbol)
    try
        p = decompress(src, dst; format)
        say(what, " ok ", p == abspath(dst), " ", filesize(p))
    catch e
        e isa DecompressError ?
            say(what, " DecompressError errno=", e.errno, " ", ispath(dst) ? "dst exists" : "no dst") :
            say(what, " other error")
    end
    return nothing
end

function show_platform(what::String, p::Union{Nothing,Base.BinaryPlatforms.Platform})
    if p === nothing
        say(what, " none")
    else
        say(what, " ", arch(p), " ", os(p), " ", something(libc(p), "-"), " julia_version=", p["julia_version"],
            " cuda=", haskey(p, "cuda") ? p["cuda"] : "-", " ", triplet(p))
    end
    return nothing
end

function platform_main()::Int32
    t = WasmHost.Platform.tags()
    if t === nothing
        say("P1 none")
    else
        io = IOBuffer()
        for (k, v) in t
            print(io, k, '=', v, ' ')
        end
        say("P1 ", String(take!(io)))
    end
    show_platform("P2", WasmHost.Platform.host_platform())
    # (a variable of an older name, which the program names)
    show_platform("P3", WasmHost.Platform.host_platform(names = ("E2E_UNSET_PLATFORM", "E2E_OLD_PLATFORM")))
    return Int32(0)
end

function main()::Int32
    i, o = indir(), outdir()
    gz = joinpath(i, "artifact.tar.gz")
    attempt("D1 gzip", gz, joinpath(o, "gz.tar"), :auto)
    attempt("D2 zstd", joinpath(i, "artifact.tar.zst"), joinpath(o, "zst.tar"), :auto)
    attempt("D3 deflate", joinpath(i, "artifact.tar.zz"), joinpath(o, "zz.tar"), :deflate)
    attempt("D4 gzip-explicit", gz, joinpath(o, "gz2.tar"), :gzip)
    attempt("D5 wrong-format", gz, joinpath(o, "wrong.tar"), :zstd)
    attempt("D6 not-compressed", joinpath(o, "gz.tar"), joinpath(o, "plain.out"), :auto)
    attempt("D7 missing", joinpath(i, "missing.tar.gz"), joinpath(o, "missing.tar"), :auto)
    return platform_main()
end
end
