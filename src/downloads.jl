"""
    WasmHost.Downloads

HTTP requests performed by the host's `fetch`. The package extension `WasmHostDownloadsExt`
(loaded with Downloads and WasmCodegen) builds `Downloads.request` on [`request`](@ref) in the
compiled module.

Protocol `wasm-fetch 1` (UTF-8 text, one field per line, no line breaks inside a field), in
`<spool>/<id>.req` and `<spool>/<id>.res`, or in the buffers of `wasm_host.http_request`:

    request:  "wasm-fetch 1", method, url, output path ("" = discard the body),
              input path ("" = no body), timeout in seconds ("inf"), then "name: value" headers
    response: "wasm-fetch 1", code (0 = a response, else a libcurl error code), error message,
              final url (after redirects), status, status line ("HTTP/1.1 200 OK"),
              then "name: value" headers of the final response (names in lower case)
"""
module Downloads

using ..WasmHost: WasmHost, spool_dir, spool_exchange, split_lines

const PROTOCOL = "wasm-fetch 1"

"The outcome of a request (see the module's documentation)."
struct Result
    code::Int
    message::String
    url::String
    status::Int
    status_line::String
    headers::Vector{Pair{String,String}}
end

field(s::String, what::String) = WasmHost.field(s, PROTOCOL, what)

no_host(url::String, msg::String) = Result(2, string("wasm-fetch: ", msg), url, 0, "", Pair{String,String}[])

"""
    request_text(url, method, headers, input, output, timeout) -> String

The text of a request. Throws an `ArgumentError` for a field with a line break.
"""
function request_text(url::String, method::String, headers::Vector{Pair{String,String}},
                      input::String, output::String, timeout::Float64)::String
    io = IOBuffer()
    println(io, PROTOCOL)
    println(io, field(method, "method"))
    println(io, field(url, "url"))
    println(io, field(output, "output path"))
    println(io, field(input, "input path"))
    println(io, isfinite(timeout) ? string(timeout) : "inf")
    for (k, v) in headers
        println(io, field(k, "header name"), ": ", field(v, "header value"))
    end
    return String(take!(io))
end

"""
    request(url, method, headers, input, output, timeout) -> Result

Perform the request through the host. `input`/`output` are paths of the program's filesystem
(\"\": none). Never throws for a failure of the request itself: that is `Result.code != 0`
(code 2 when the host has no fetch).
"""
function request(url::String, method::String, headers::Vector{Pair{String,String}},
                 input::String, output::String, timeout::Float64)::Result
    isempty(spool_dir()) && return no_host(url, "the host provides no fetch (WASMHOST_SPOOL is not set)")
    text = request_text(url, method, headers, input, output, timeout)
    res = WasmHost.transport() === :import ? request_import(text) : spool_exchange(text, ".req", ".res")
    res === nothing && return no_host(url, "no response from the host (is its adapter installed?)")
    return parse_result(split_lines(res), url)
end

"The response text for the request text, through the `wasm_host` import (defined by the extension)."
function request_import end

"The [`Result`](@ref) of the lines of a response; a malformed response is code 2."
function parse_result(lines::Vector{String}, url::String)::Result
    length(lines) >= 6 && lines[1] == PROTOCOL ||
        return no_host(url, "malformed response from the host")
    code = something(tryparse(Int, lines[2]), 2)
    status = something(tryparse(Int, lines[5]), 0)
    headers = Pair{String,String}[]
    for i in 7:length(lines)
        l = lines[i]
        j = findfirst(':', l)
        j === nothing && continue
        push!(headers, String(lowercase(l[1:prevind(l, j)])) => String(strip(l[nextind(l, j):end])))
    end
    return Result(code, lines[3], lines[4], status, lines[6], headers)
end

end # module Downloads
