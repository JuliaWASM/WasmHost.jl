# julia --project=ENV build.jl OUT.wasm [spool|import] : compile prog.jl's FetchProg.main for WASI
using WasmCodegen, Downloads, WasmFetch
Base.get_extension(WasmFetch, :WasmFetchDownloadsExt) === nothing && error("WasmFetchDownloadsExt is not loaded")
include(joinpath(@__DIR__, "prog.jl"))
out = ARGS[1]
transport = get(ARGS, 2, "spool")
kw = (;)
if transport == "import"
    # (needs a WasmCodegen with Config(import_libraries))
    @eval WasmFetch transport() = :import
    kw = (; import_libraries = ["wasm_fetch"])
end
cfg = WasmCodegen.Config(; host = :wasi, trim = :safe, on_unsupported = :error, verify = :warn, kw...)
t = time()
c = WasmCodegen.compile([WasmCodegen.Entry(FetchProg.main, (); name = "main")]; config = cfg)
println("compiled ($(transport)) in ", round(time() - t; digits = 1), " s: ", length(c.bytes), " bytes, ",
        length(c.cgm.diagnostics), " diagnostics")
write(out, c.bytes)
