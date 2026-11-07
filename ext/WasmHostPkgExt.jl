"""
    WasmHostPkgExt

Pkg's decompression for modules compiled by WasmCodegen: methods of WasmCodegen's overlay method
table (`WasmCodegen.Runtime.WASM_METHODS`), used only when compiling to Wasm.

Pkg decompresses its tarballs (packages, artifacts, a packed registry) at four places by reading the
output of a `zstd` or `7z` process, `open(get_extract_cmd(path))` (`PlatformEngines.unpack`,
`download_verify_unpack`, `verify_archive_tree_hash`, `Registry.uncompress_registry`). A Wasm module
has no processes. Here `get_extract_cmd(path)` returns a command that only names the file,
`wasm-decompress <path>`, and `open(f, cmd)` of such a command decompresses the file with the host
([`WasmHost.Decompress.decompress`](@ref), gzip and zstd by their magic bytes, as Pkg's
`detect_archive_format`) into a temporary file next to it, calls `f` on that file, and removes it.
`open(f, cmd)` of any other command is an error, as running any process is in a module.

Upstream, one Pkg function for the four places (`open_decompressed(f, path)`) would be the only
method to overlay, without a stand-in command.
"""
module WasmHostPkgExt

import WasmHost
import WasmCodegen
import Pkg
using Pkg: PlatformEngines

const MARKER = "wasm-decompress"

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS PlatformEngines.get_extract_cmd(tarball_path::AbstractString) =
    Cmd(String[MARKER, String(tarball_path)])

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.open(f::Function, cmd::Cmd)
    args = cmd.exec
    (length(args) == 2 && args[1] == MARKER) ||
        throw(ArgumentError(string("cannot run a process in WebAssembly: ", isempty(args) ? "" : args[1])))
    tmp = string(args[2], ".", string(rand(UInt32); base = 16), ".decompressed")
    WasmHost.Decompress.decompress(args[2], tmp)
    try
        return open(f, tmp)
    finally
        rm(tmp; force = true)
    end
end

end # module
