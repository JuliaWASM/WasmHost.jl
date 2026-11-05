# End-to-end check: compile test/e2e/prog.jl (plain Downloads calls) with WasmCodegen, run it in
# Node with the host adapter, and compare its output and downloaded bytes with the same program
# run natively (Downloads + libcurl), against a local HTTP server (server.mjs).
#
#   julia test/e2e/e2e.jl /path/to/WasmCodegen.jl [spool|import|all]
#
# Environment: JULIA (default: this julia), NODE (default: `node` on PATH, Node 22+ with JSPI),
# WASMBUILDER / IRSTRUCTURIZER (paths, optional: otherwise WasmCodegen's own [sources]),
# E2E_REUSE=1 (run modules an earlier run built, without rebuilding them).
# WasmCodegen needs the WASI filesystem and environment for `host = :wasi`; `import` also needs
# `Config(import_libraries)`.
using TOML

const HERE = @__DIR__
const ROOT = dirname(dirname(HERE))
wcg = abspath(ARGS[1])
which = get(ARGS, 2, "spool")
julia = get(ENV, "JULIA", joinpath(Sys.BINDIR, Base.julia_exename()))
node = get(ENV, "NODE", something(Sys.which("node"), "node"))
work = mkpath(joinpath(HERE, "work"))

# the environment: WasmCodegen, its WasmBuilder and IRStructurizer, WasmFetch, Downloads
function setup_env(dir)
    wp = TOML.parsefile(joinpath(wcg, "Project.toml"))
    deps = Dict("WasmCodegen" => wp["uuid"], "WasmFetch" => TOML.parsefile(joinpath(ROOT, "Project.toml"))["uuid"],
                "Downloads" => "f43a241f-c20a-4ad4-852c-f6b1247861c6")
    sources = Dict{String,Any}("WasmCodegen" => Dict("path" => wcg), "WasmFetch" => Dict("path" => ROOT))
    for (name, var) in (("WasmBuilder", "WASMBUILDER"), ("IRStructurizer", "IRSTRUCTURIZER"))
        deps[name] = wp["deps"][name]
        src = haskey(ENV, var) ? Dict("path" => abspath(ENV[var])) : copy(wp["sources"][name])
        haskey(src, "path") && (src["path"] = abspath(wcg, src["path"]))
        sources[name] = src
    end
    mkpath(dir)
    open(io -> TOML.print(io, Dict("deps" => deps, "sources" => sources); sorted = true), joinpath(dir, "Project.toml"), "w")
    run(`$julia --startup-file=no --project=$dir -e "using Pkg; Pkg.instantiate()"`)
    return dir
end

tlines(s) = filter(l -> startswith(l, "T"), split(s, '\n'))

# the output of `cmd`, stdout and stderr together
function output(cmd)
    p = Pipe()
    proc = run(pipeline(ignorestatus(cmd); stdout = p, stderr = p); wait = false)
    close(p.in)
    out = read(p, String)
    wait(proc)
    return out
end

env = setup_env(joinpath(work, "env"))
native = read(addenv(`$node $(joinpath(HERE, "native.mjs")) $(joinpath(work, "native"))`,
                     "JULIA" => julia, "E2E_PROJECT" => env), String)
print("native:\n", native)
ok = !isempty(tlines(native))
for transport in (which == "all" ? ["spool", "import"] : [which])
    wasm = joinpath(work, "fetch-$transport.wasm")
    # (E2E_REUSE=1: a module already built by an earlier run is run again, not rebuilt)
    get(ENV, "E2E_REUSE", "") == "1" && isfile(wasm) ||
        run(`$julia --startup-file=no --project=$env $(joinpath(HERE, "build.jl")) $wasm $transport`)
    for mode in (transport == "import" ? ["import"] : ["jspi", "sync"])
        out = output(`$node --experimental-wasm-jspi --disable-warning=ExperimentalWarning $(joinpath(HERE, "run.mjs")) $wasm $mode $(joinpath(work, mode))`)
        same = tlines(out) == tlines(native) && occursin("identical to the server's: true", out) && occursin("spool files left: 0", out)
        println("== $transport/$mode: ", same ? "IDENTICAL to native" : "DIFFERENT", "\n", out)
        global ok &= same
    end
end
println(ok ? "E2E PASS" : "E2E FAIL")
exit(ok ? 0 : 1)
