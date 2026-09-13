# Select the ABI-correct standalone binding generated from the matching
# LibRaw_jll artifact. `LIBRAWWRAPPER_TARGET` is useful for cross testing.
const _libraw_target = get(ENV, "LIBRAWWRAPPER_TARGET", begin
    if Sys.iswindows() && Sys.ARCH === :x86_64
        "x86_64-w64-mingw32"
    elseif Sys.iswindows() && Sys.ARCH === :i686
        "i686-w64-mingw32"
    elseif Sys.isapple() && Sys.ARCH === :x86_64
        "x86_64-apple-darwin14"
    elseif Sys.isapple() && Sys.ARCH === :aarch64
        "aarch64-apple-darwin20"
    elseif Sys.islinux() && Sys.ARCH === :x86_64
        "x86_64-linux-gnu"
    elseif Sys.islinux() && Sys.ARCH === :aarch64
        "aarch64-linux-gnu"
    else
        error("LibRawWrapper has no generated binding for $(Sys.MACHINE)")
    end
end)
const _libraw_binding = joinpath(@__DIR__, "bindings", "$_libraw_target.jl")
isfile(_libraw_binding) || error("missing LibRawWrapper binding for target $_libraw_target")
include(_libraw_binding)
