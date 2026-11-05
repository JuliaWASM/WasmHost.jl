# Native tests of the protocol (no WasmCodegen needed). The end-to-end check, which compiles a
# program with WasmCodegen and runs it in Node, is test/e2e/e2e.jl.
using Test, WasmFetch
using WasmFetch: request_text, parse_result, split_lines, Result

const JS = joinpath(dirname(@__DIR__), "js", "common", "protocol.mjs")

withenv_spool(f, dir) = withenv(f, "WASM_FETCH_SPOOL" => dir)

@testset "WasmFetch" begin
    @testset "request text" begin
        t = request_text("http://h/x", "GET", ["Accept" => "*/*", "X-A" => "b c"], "", "/w/out.bin", Inf)
        @test t == "wasm-fetch 1\nGET\nhttp://h/x\n/w/out.bin\n\ninf\nAccept: */*\nX-A: b c\n"
        @test split(request_text("u", "PUT", Pair{String,String}[], "/w/in", "", 2.5), '\n')[5:6] == ["/w/in", "2.5"]
        @test_throws ArgumentError request_text("http://h/\nx", "GET", Pair{String,String}[], "", "", Inf)
        @test_throws ArgumentError request_text("u", "GET", ["X" => "a\r\nY: b"], "", "", Inf)
    end

    @testset "response parsing" begin
        lines = ["wasm-fetch 1", "0", "", "http://h/final", "200", "HTTP/1.1 200 OK",
                 "Content-Type: text/plain", "x-two:  spaced ", "no colon line", "set-cookie: a=1; Path=/"]
        r = parse_result(lines, "http://h/x")
        @test r isa Result
        @test (r.code, r.message, r.url, r.status, r.status_line) == (0, "", "http://h/final", 200, "HTTP/1.1 200 OK")
        @test r.headers == ["content-type" => "text/plain", "x-two" => "spaced", "set-cookie" => "a=1; Path=/"]
        e = parse_result(["wasm-fetch 1", "7", "connect ECONNREFUSED", "http://h/x", "0", ""], "http://h/x")
        @test (e.code, e.message, e.status, e.headers) == (7, "connect ECONNREFUSED", 0, Pair{String,String}[])
        # malformed: another protocol, too few lines
        @test parse_result(["wasm-fetch 2", "0", "", "u", "200", ""], "u").code == 2
        @test parse_result(["wasm-fetch 1", "0"], "u").code == 2
        @test split_lines("a\nb\n") == ["a", "b"]
        @test split_lines("a\n\nb") == ["a", "", "b"]
        @test split_lines("") == String[]
    end

    @testset "without a host" begin
        # no spool directory: a failure of the request (code 2), not an exception
        withenv("WASM_FETCH_SPOOL" => nothing) do
            r = WasmFetch.request("http://h/x", "GET", Pair{String,String}[], "", "", Inf)
            @test r.code == 2 && occursin("WASM_FETCH_SPOOL", r.message)
        end
        # a spool directory but no adapter answering it: code 2, and nothing left behind
        dir = mktempdir()
        withenv_spool(dir) do
            r = WasmFetch.request("http://h/x", "GET", Pair{String,String}[], "", "", Inf)
            @test r.code == 2 && occursin("no response", r.message)
        end
        @test isempty(readdir(dir))
        @test WasmFetch.transport() === :spool
    end

    # the request as the JavaScript adapter parses it, and its response as Julia parses it
    node = Sys.which("node")
    @testset "protocol round trip with the JavaScript adapter" begin
        if node === nothing
            @test_skip "node not found"
        else
            req = request_text("http://h/x?a=1", "POST", ["X-Probe" => "v: w"], "/w/in", "/w/out", 3.0)
            script = """
            import { parseRequest, formatResult } from $(repr("file://" * JS));
            const req = parseRequest(process.argv.at(-1));
            process.stdout.write(formatResult({ code: 0, message: '', url: req.url + '#final', status: 201,
              statusLine: 'HTTP/1.1 201 Created', headers: [['x-echo', JSON.stringify([req.method, req.output, req.input, req.timeout, req.headers])]] }));
            """
            out = read(`$node --input-type=module -e $script $req`, String)
            r = parse_result(split_lines(out), "http://h/x?a=1")
            @test (r.code, r.url, r.status, r.status_line) == (0, "http://h/x?a=1#final", 201, "HTTP/1.1 201 Created")
            @test r.headers == ["x-echo" => """["POST","/w/out","/w/in",3,[["X-Probe","v: w"]]]"""]
        end
    end
end
