"""
    WasmHostPageExt

[`WasmHost.Page`](@ref) in modules compiled by WasmCodegen: methods of its overlay method table
(`WasmCodegen.Runtime.WASM_METHODS`) over the import library `wasm_host_page`, which the program
declares (`Config(import_libraries = ["wasm_host_page"])`). Natively `Page` stays its own (the
native queues).

The bytes go through the linear memory in one of two ways, chosen when the module is compiled:

- **Staging** (WasmCodegen's `Runtime.Staging`, internal, `host = :wasi`): a chunk of its data
  arena (at most `Staging.CHUNK` bytes) per call, copied with `copy_to_linear!` and
  `copy_from_linear!`, as `WasmHostDownloadsExt`'s import transport does. Both directions.
- **Bytes arguments** (gbaraldi/WasmCodegen.jl#91): the code generator copies a `Vector{UInt8}`
  or `String` argument of a declared import to the memory and passes its offset and length, so
  a message is one call, also for `host = :js`. [`bytes_arguments`](@ref) says whether this
  WasmCodegen does. Receiving still uses Staging.
"""
module WasmHostPageExt

import WasmHost
import WasmCodegen

const Page = WasmHost.Page
const Staging = WasmCodegen.Runtime.Staging

"""
    bytes_arguments() -> Bool

Whether this WasmCodegen passes the bytes of a `Vector{UInt8}` or `String` argument of a declared
import (gbaraldi/WasmCodegen.jl#91), by the capability itself: the argument types it accepts as
bytes (`WasmCodegen.IMPORT_BYTES`). A constant, so a module contains only the way it uses.
"""
bytes_arguments() = BYTES_ARGUMENTS
const BYTES_ARGUMENTS = isdefined(WasmCodegen, :IMPORT_BYTES) &&
                        WasmCodegen.IMPORT_BYTES isa Tuple &&
                        Vector{UInt8} in WasmCodegen.IMPORT_BYTES && String in WasmCodegen.IMPORT_BYTES

## sending

# one call: the code generator copies the bytes (#91)
send_direct(bytes::Vector{UInt8}) =
    ccall((:send, "wasm_host_page"), Cvoid, (Vector{UInt8}, Int32), bytes, Int32(1))
send_direct(s::String) =
    ccall((:send, "wasm_host_page"), Cvoid, (String, Int32), s, Int32(1))

# bytes i + 1, ..., i + k of the message, through Staging's data arena
function send_chunk(bytes::Union{Vector{UInt8},String}, i::Int, k::Int, last::Bool)
    Staging.with_scope() do
        off = Staging.alloc_data(k; align = 1)
        Staging.copy_to_linear!(off, bytes, i + 1, k)
        ccall((:send, "wasm_host_page"), Cvoid, (UInt32, UInt32, Int32), off, UInt32(k), Int32(last))
    end
    return nothing
end

# in chunks of at most Staging.CHUNK bytes (one call for an empty message)
function send_staged(bytes::Union{Vector{UInt8},String})
    n = sizeof(bytes)
    i = 0
    while true
        k = min(n - i, Int(Staging.CHUNK))
        last = i + k >= n
        send_chunk(bytes, i, k, last)
        last && return nothing
        i += k
    end
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS WasmHost.Page.send(bytes::Vector{UInt8}) =
    (BYTES_ARGUMENTS ? send_direct(bytes) : send_staged(bytes); nothing)
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS WasmHost.Page.send(s::String) =
    (BYTES_ARGUMENTS ? send_direct(s) : send_staged(s); nothing)

## receiving (Staging: `host = :wasi`)

# bytes i + 1, ..., i + k of the host's next message into buf
function read_chunk!(buf::Vector{UInt8}, i::Int, k::Int)
    Staging.with_scope() do
        off = Staging.alloc_data(k; align = 1)
        ccall((:read, "wasm_host_page"), Cvoid, (UInt32, UInt32, UInt32), off, UInt32(i), UInt32(k))
        Staging.copy_from_linear!(buf, i + 1, off, k)
    end
    return nothing
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function WasmHost.Page.receive()::Union{Vector{UInt8},Nothing}
    n = Int(ccall((:pending, "wasm_host_page"), Int32, ()))
    n < 0 && return nothing
    buf = Vector{UInt8}(undef, n)
    i = 0
    while i < n
        k = min(n - i, Int(Staging.CHUNK))
        read_chunk!(buf, i, k)
        i += k
    end
    ccall((:pop, "wasm_host_page"), Cvoid, ())
    return buf
end

end # module
