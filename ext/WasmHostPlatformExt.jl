"""
    WasmHostPlatformExt

`Base.BinaryPlatforms.HostPlatform()` for modules compiled by WasmCodegen: a method of WasmCodegen's
overlay method table (`WasmCodegen.Runtime.WASM_METHODS`), used only when compiling to Wasm.

Natively `HostPlatform()` is the platform Julia was built for (`Sys.MACHINE`, the libc, the
libgfortran and libstdc++ versions, the CPU features): in a Wasm module that would be the
platform of the build machine, captured at build time. A program that picks binaries for the
machine it runs on (Pkg's artifacts) needs the host's: here it is
[`WasmHost.Platform.host_platform`](@ref), the tags of the host's `WASMHOST_PLATFORM`, with this
program's Julia version. A host that gives no tags makes `HostPlatform()` an error.
"""
module WasmHostPlatformExt

import WasmHost
import WasmCodegen
using Base.BinaryPlatforms: BinaryPlatforms, Platform

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function BinaryPlatforms.HostPlatform()
    p = WasmHost.Platform.host_platform()
    p === nothing && error("HostPlatform(): the host gave no platform tags (WASMHOST_PLATFORM is not set)")
    return p
end

end # module
