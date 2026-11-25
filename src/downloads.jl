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

The text of a request, `timeout` in seconds (`Inf`: none). Throws an `ArgumentError` for a
field with a line break, and for a timeout that is not positive ([`timeout_ms`](@ref)).
"""
request_text(url::String, method::String, headers::Vector{Pair{String,String}},
             input::String, output::String, timeout::Real)::String =
    request_text_ms(url, method, headers, input, output, timeout_ms(timeout))

# The same, the timeout as `timeout_ms` gives it. It goes in seconds ("inf" for 0, none), the
# protocol's unit: the host gets the milliseconds back by rounding a thousand times that number.
function request_text_ms(url::String, method::String, headers::Vector{Pair{String,String}},
                         input::String, output::String, timeout_ms::Int64)::String
    io = IOBuffer()
    println(io, PROTOCOL)
    println(io, field(method, "method"))
    println(io, field(url, "url"))
    println(io, field(output, "output path"))
    println(io, field(input, "input path"))
    println(io, timeout_ms == 0 ? "inf" : string(timeout_ms / 1000))
    for (k, v) in headers
        println(io, field(k, "header name"), ": ", field(v, "header value"))
    end
    return String(take!(io))
end

# C's `long` in a module for wasm32, as in a 32-bit native build (`Clong` here is the build process's)
const Long = Int32

"""
    timeout_ms(timeout) -> Int64

The `timeout` keyword of `Downloads.request` as the milliseconds libcurl gets from the native
method where `long` has 32 bits (0: no timeout), or that method's `ArgumentError` for one that
is not positive. As Downloads' `set_timeout`: rounded to a whole millisecond (the nearest, a
tie to the even one, so less than half of one is none); past 2147483 s, the last that fits a
`long` in milliseconds, to a whole second; past a `long` of seconds, and for `Inf`, none.
"""
function timeout_ms(timeout::Real)::Int64
    timeout > 0 || throw(ArgumentError("timeout must be positive, got $timeout"))
    timeout ≤ typemax(Long) ÷ 1000 && return Int64(round(Long, timeout * 1000))
    return timeout ≤ typemax(Long) ? 1000 * Int64(round(Long, timeout)) : Int64(0)
end

"""
    header_pairs(headers, user_agent) -> Vector{Pair{String,String}}

The `headers` keyword of `Downloads.request` as the headers to send, with `user_agent` unless
`headers` has a `User-Agent`. `name => nothing` sends no such header (libcurl's `"Name:"`): for
a header the host's `fetch` adds itself, as `User-Agent` and `Accept`, that leaves it to the
host (the native method sends none; Node's `fetch` sends its own). An entry that is not such a
pair is the native method's `ArgumentError`, and so is a NUL in a header, sent or not (natively
it is given to libcurl as a C string either way).
"""
function header_pairs(headers, user_agent::String)::Vector{Pair{String,String}}
    hdrs = Pair{String,String}[]
    agent = false
    for hdr in headers
        hdr isa Pair{<:AbstractString,<:Union{AbstractString,Nothing}} ||
            throw(ArgumentError("invalid header: $(repr(hdr))"))
        k, v = hdr
        # (libcurl's form of the header: `Name:` sends none, `Name;` one without a value)
        line = v === nothing ? "$k:" : isempty(v) ? "$k;" : "$k: $v"
        occursin('\0', line) && throw(ArgumentError("embedded NULs are not allowed in C strings: $(repr(line))"))
        agent |= lowercase(k) == "user-agent"
        v === nothing || push!(hdrs, String(k) => String(v))
    end
    agent || push!(hdrs, "User-Agent" => user_agent)
    return hdrs
end

"""
    request(url, method, headers, input, output, timeout) -> Result

Perform the request through the host. `input`/`output` are paths of the program's filesystem
(\"\": none), `timeout` is in seconds (`Inf`: none; made the milliseconds libcurl would get by
[`timeout_ms`](@ref), whose `ArgumentError` for one that is not positive is thrown here).
Never throws for a failure of the request itself: that is `Result.code != 0` (code 2 when the
host has no fetch).
"""
request(url::String, method::String, headers::Vector{Pair{String,String}},
        input::String, output::String, timeout::Real)::Result =
    request_ms(url, method, headers, input, output, timeout_ms(timeout))

# The same, the timeout as `timeout_ms` gave it (the extension has it already: Downloads
# checks the timeout before it opens the files).
function request_ms(url::String, method::String, headers::Vector{Pair{String,String}},
                    input::String, output::String, timeout_ms::Int64)::Result
    isempty(spool_dir()) && return no_host(url, "the host provides no fetch (WASMHOST_SPOOL is not set)")
    text = request_text_ms(url, method, headers, input, output, timeout_ms)
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
