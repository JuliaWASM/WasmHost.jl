"""
    WasmFetch

HTTP requests for Julia programs compiled to WebAssembly (WASI preview 1) by WasmCodegen,
performed by the host's `fetch`. With Downloads and WasmCodegen loaded, the package extension
`WasmFetchDownloadsExt` makes `Downloads.request` (and so `Downloads.download`) use it in the
compiled module; natively nothing changes.

Requests reach the host by one of two transports (see [`transport`](@ref)):

- `:spool` (the default): files of a spool directory, `ENV["WASM_FETCH_SPOOL"]`, inside one of
  the WASI preopens. The program writes a request, `<spool>/<id>.req`, then opens
  `<spool>/<id>.res`. The host adapter (e.g. `js/node/spool.mjs`) intercepts that `path_open`,
  performs the request (writing the body to the file the request names), writes the response
  file and lets the open proceed. The module needs no import of its own.
- `:import`: the import library `wasm_fetch` (e.g. `js/node/imports.mjs`), for a code
  generator that lets a program declare one (`Config(import_libraries = ["wasm_fetch"])`).

Protocol, version 1 (UTF-8 text, one field per line, no line breaks inside a field):

    request:  "wasm-fetch 1", method, url, output path ("" = discard the body),
              input path ("" = no body), timeout in seconds ("inf"), then "name: value" headers
    response: "wasm-fetch 1", code (0 = a response, else a libcurl error code), error message,
              final url (after redirects), status, status line ("HTTP/1.1 200 OK"),
              then "name: value" headers of the final response (names in lower case)

Paths are the program's (WASI) paths; the host maps them through its preopens.
"""
module WasmFetch

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

const COUNTER = Ref(0)

"The program's path of the spool directory, or \"\" when the host has none."
spool_dir()::String = get(ENV, "WASM_FETCH_SPOOL", "")

function field(s::String, what::String)::String
    (occursin('\n', s) || occursin('\r', s)) &&
        throw(ArgumentError(string("wasm-fetch: the ", what, " contains a line break")))
    return s
end

"A fresh path in the spool directory, ending with `suffix` (for request bodies and the like)."
function spool_path(suffix::String)::String
    COUNTER[] += 1
    return joinpath(spool_dir(), string(COUNTER[], "-", string(rand(UInt32); base = 16), suffix))
end

no_host(url::String, msg::String) = Result(2, string("wasm-fetch: ", msg), url, 0, "", Pair{String,String}[])

"""
    request_text(url, method, headers, input, output, timeout) -> String

The text of a request (protocol 1). Throws an `ArgumentError` for a field with a line break.
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
    isempty(spool_dir()) && return no_host(url, "the host provides no fetch (WASM_FETCH_SPOOL is not set)")
    text = request_text(url, method, headers, input, output, timeout)
    res = transport() === :import ? request_import(text) : request_spool(text)
    res === nothing && return no_host(url, "no response from the host (is its fetch adapter installed?)")
    return parse_result(split_lines(res), url)
end

"""
    transport() -> Symbol

How requests reach the host: `:spool` (files of the spool directory; no import of its own) or
`:import` (the import library `wasm_fetch`). A build that uses the import library redefines it
before compiling, `WasmFetch.transport() = :import`, and passes
`Config(import_libraries = ["wasm_fetch"])` to WasmCodegen. It is a function, not a setting
read at run time, so that the module contains only the transport it uses.
"""
transport() = :spool

"The response text for the request text, through the spool directory (or nothing)."
function request_spool(text::String)::Union{Nothing,String}
    base = spool_path("")
    req, res = base * ".req", base * ".res"
    write(req, text)
    out = nothing
    try
        # (the host performs the request when the response file is opened)
        out = read(res, String)
    catch
        out = nothing
    finally
        rm(req; force = true)
        rm(res; force = true)
    end
    return out
end

"The response text for the request text, through the `wasm_fetch` import (defined by the extension)."
function request_import end

# (`readlines` iterates with a function value: not in a trimmed program)
function split_lines(s::String)::Vector{String}
    v = String[String(l) for l in split(s, '\n')]
    !isempty(v) && isempty(v[end]) && pop!(v)
    return v
end

"The [`Result`](@ref) of the lines of a response (protocol 1); a malformed response is code 2."
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

end # module
