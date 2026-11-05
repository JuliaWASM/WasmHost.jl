# `Downloads.request` for modules compiled by WasmCodegen: a method of WasmCodegen's overlay
# method table (`Runtime.WASM_METHODS`), so the native method (libcurl) stays as it is in the
# build process while the module compiles this one. `Downloads.download` is Downloads' own: it
# calls `request`. Loaded when both Downloads and WasmCodegen are loaded, i.e. in any build
# process that compiles a program using Downloads.
#
# `Runtime.WASM_METHODS` is WasmCodegen's internal API today (it is how its own runtime replaces
# methods); this extension relies on it.
module WasmHostDownloadsExt

using WasmHost
using Downloads
using Downloads: Response, RequestError
import WasmCodegen

# (the host side of the requests: `WasmHost.Downloads`, not the stdlib)
const Host = WasmHost.Downloads

## the import transport (`WasmHost.transport() === :import`)

# `wasm_host.http_request(req, req_len, res, res_cap) -> len` with buffers in WasmCodegen's
# staging area of the linear memory (`Runtime.Staging`, also internal); needs
# `Config(import_libraries = ["wasm_host"])`
const Staging = WasmCodegen.Runtime.Staging
const RESPONSE_CAP = 1 << 16

function Host.request_import(text::String)::Union{Nothing,String}
    return Staging.with_scope() do
        n = sizeof(text)
        req = Staging.alloc_data(n; align = 1)
        Staging.copy_to_linear!(req, text, 1, n)
        res = Staging.alloc_data(RESPONSE_CAP; align = 1)
        len = ccall((:http_request, "wasm_host"), Int32, (UInt32, UInt32, UInt32, UInt32),
                    req, UInt32(n), res, UInt32(RESPONSE_CAP))
        len < 0 && return nothing
        buf = Vector{UInt8}(undef, len)
        Staging.copy_from_linear!(buf, 1, res, Int(len))
        return String(buf)
    end
end

## Downloads.request

# (what the native method sends unless the caller sets one)
const USER_AGENT = Downloads.Curl.USER_AGENT

header_pairs(headers) = Pair{String,String}[String(k) => String(v) for (k, v) in headers]

# the request's body: a path of the program, or an IO copied to a spool file first
input_path(::Nothing) = ("", false)
input_path(path::AbstractString) = (String(abspath(path)), false)
function input_path(io::IO)
    p = WasmHost.spool_path(".in")
    open(f -> write(f, read(io)), p, "w")
    return (p, true)
end

# where the host writes the body: a path of the program, or a spool file copied into the IO
output_path(::Nothing) = ""
output_path(path::AbstractString) = String(abspath(path))
output_path(::IO) = WasmHost.spool_path(".out")

# the body into the output (for an IO), and its size in bytes
copy_body!(::Nothing, ::String) = 0
copy_body!(::AbstractString, p::String) = isfile(p) ? Int(filesize(p)) : 0
function copy_body!(io::IO, p::String)
    isfile(p) || return 0
    # (a loop, not an `open(...) do` closure: a counter it updated would be boxed)
    total = 0
    f = open(p)
    try
        buf = Vector{UInt8}(undef, 1 << 16)
        while !eof(f)
            n = readbytes!(f, buf)
            write(io, view(buf, 1:n))
            total += n
        end
    finally
        close(f)
    end
    return total
end

function scheme(url::String)
    i = findfirst(':', url)
    return i === nothing ? nothing : lowercase(url[1:prevind(url, i)])
end

# the Content-Length of the response, 0 without one (as libcurl's progress total)
function content_length(headers::Vector{Pair{String,String}})
    for (k, v) in headers
        k == "content-length" && return something(tryparse(Int, v), 0)
    end
    return 0
end

function wasm_request(url::String, input, output, method, headers, timeout::Float64, progress,
                      throw::Bool)::Union{Response,RequestError}
    meth = method === nothing ? (input !== nothing ? "PUT" : output !== nothing ? "GET" : "HEAD") :
           String(method)
    hdrs = header_pairs(headers)
    any(kv -> lowercase(kv[1]) == "user-agent", hdrs) || push!(hdrs, "User-Agent" => USER_AGENT)
    inp, in_tmp = input_path(input)
    out = output_path(output)
    local r::Host.Result
    nbytes = 0
    try
        r = Host.request(url, meth, hdrs, inp, out, timeout)
        r.code == 0 && (nbytes = copy_body!(output, out))
    finally
        in_tmp && rm(inp; force = true)
        output isa IO && rm(out; force = true)
    end
    if r.code == 0 && progress !== nothing
        # (one call, with the complete transfer: what libcurl's last progress call reports)
        progress(content_length(r.headers), nbytes, 0, 0)
    end
    response = Response(r.code == 0 ? scheme(r.url) : nothing, r.code == 0 ? r.url : url,
                        r.status, r.status_line, r.headers)
    r.code == 0 && return response
    err = RequestError(url, r.code, r.message, response)
    throw && Base.throw(err)
    return err
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Downloads.request(
    url        :: AbstractString;
    input      :: Union{Downloads.ArgRead, Nothing} = nothing,
    output     :: Union{Downloads.ArgWrite, Nothing} = nothing,
    method     :: Union{AbstractString, Nothing} = nothing,
    headers    :: Union{AbstractVector, AbstractDict} = Pair{String,String}[],
    timeout    :: Real = Inf,
    progress   :: Union{Function, Nothing} = nothing,
    verbose    :: Bool = false,
    debug      :: Union{Function, Nothing} = nothing,
    throw      :: Bool = true,
    downloader :: Union{Downloads.Downloader, Nothing} = nothing,
    interrupt  :: Union{Nothing, Base.Event} = nothing,
) :: Union{Response, RequestError}
    # (`verbose`, `debug`, `downloader` and `interrupt` have no meaning for the host's fetch)
    p = progress === nothing ? nothing :
        Downloads.p_func(progress, something(input, devnull), something(output, devnull))
    return wasm_request(String(url), input, output, method, headers, Float64(timeout), p, throw)
end

## what else Downloads needs in a trimmed module

# `status_ok` looks its test up in a `Dict{String,Function}` (a call of a function value, which
# a trimmed program cannot make): the same table as code
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Downloads.Curl.status_ok(
        proto::AbstractString, status::Integer)
    proto in ("http", "https", "ftp", "ftps", "dict", "pop3", "pop3s", "rtsp", "smtp", "smtps") &&
        return 200 <= status < 300
    proto in ("file", "ldap", "ldaps", "scp", "sftp") && return status == 0
    error("Downloads.jl doesn't know the correct request success criterion for ", proto)
end

# A `Downloader()` (made by programs that set an `easy_hook`) looks up the CA roots through
# NetworkOptions and a JLL's path (a `OncePerProcess`): TLS and its roots are the host's, so
# there are none here. The rest of `Downloader()` (a `Multi` without a libcurl handle, which is
# only made when a request is added) compiles as it is.
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Downloads.get_ca_roots() = nothing

end # module
