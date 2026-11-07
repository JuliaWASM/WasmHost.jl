# julia --project=ENV build.jl OUT.wasm [spool|import] [fetch|decompress]
# Compile an e2e program for WASI: prog.jl's FetchProg.main (fetch) or dprog.jl's
# DecompressProg.main (decompress).
using WasmCodegen, Downloads, WasmHost
Base.get_extension(WasmHost, :WasmHostDownloadsExt) === nothing && error("WasmHostDownloadsExt is not loaded")
out = ARGS[1]
transport = get(ARGS, 2, "spool")
program = get(ARGS, 3, "fetch")
entry = if program == "fetch"
    include(joinpath(@__DIR__, "prog.jl")); FetchProg.main
else
    include(joinpath(@__DIR__, "dprog.jl")); DecompressProg.main
end
kw = (;)
if transport == "import"
    # (needs a WasmCodegen with Config(import_libraries))
    @eval WasmHost transport() = :import
    kw = (; import_libraries = ["wasm_host"])
end
# (WasmHost.Platform.host_platform builds a BinaryPlatforms.Platform, whose constructor can parse
# version tags with a Regex: the host's regex engine, WasmCodegen's `julia_regex`)
program == "decompress" && (kw = (; kw..., host_extensions = [:julia_regex]))
# (the fetch program, in both transports, is built with the trim verifier as an error; decompress needs the removed julia_regex)
cfg = WasmCodegen.Config(; host = :wasi, trim = :safe, on_unsupported = :error, verify = program == "fetch" ? :error : :warn, kw...)
t = time()
c = WasmCodegen.compile([WasmCodegen.Entry(entry, (); name = "main")]; config = cfg)
println("compiled ($program, $transport) in ", round(time() - t; digits = 1), " s: ", length(c.bytes), " bytes, ",
        length(c.cgm.diagnostics), " diagnostics")
write(out, c.bytes)
