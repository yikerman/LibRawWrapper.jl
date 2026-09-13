using Clang.Generators
using LibRaw_jll
cd(@__DIR__)

include_dir = normpath(LibRaw_jll.artifact_dir, "include")
header = joinpath(include_dir, "libraw", "libraw.h")

options = load_options(joinpath(@__DIR__, "generator.toml"))
args = get_default_args()
push!(args, "-x", "c", "-std=c11", "-I$include_dir")

ctx = create_context([header], args, options)
build!(ctx)

output = joinpath(@__DIR__, "..", "src", "raw.jl")
text = read(output, String)
# Clang.jl preserves several LibRaw preprocessor macros as Julia expressions.
# The version macros refer to C-only helpers/tokens (`Release`,
# `LIBRAW_VERSION_MAKE`, and `LIBRAW_MAKE_VERSION`) that do not exist in the
# generated Julia module, so normalize them into equivalent Julia values.
text = replace(
    text,
    "const LIBRAW_VERSION_TAIL = Release" => "const LIBRAW_VERSION_TAIL = \"Release\"",
)
text = replace(
    text,
    "const LIBRAW_VERSION_STR = LIBRAW_VERSION_MAKE(LIBRAW_MAJOR_VERSION, LIBRAW_MINOR_VERSION, LIBRAW_PATCH_VERSION, LIBRAW_VERSION_TAIL)" => "const LIBRAW_VERSION_STR = string(LIBRAW_MAJOR_VERSION, \".\", LIBRAW_MINOR_VERSION, \".\", LIBRAW_PATCH_VERSION, \"-Release\")",
)
text = replace(
    text,
    "const LIBRAW_VERSION = LIBRAW_MAKE_VERSION(LIBRAW_MAJOR_VERSION, LIBRAW_MINOR_VERSION, LIBRAW_PATCH_VERSION)" => "const LIBRAW_VERSION = (LIBRAW_MAJOR_VERSION << 16) | (LIBRAW_MINOR_VERSION << 8) | LIBRAW_PATCH_VERSION",
)
# Generated functions use `ccall((:symbol, libraw), ...)`; bind that symbol
# to the shared library exported by the same LibRaw_jll artifact that supplied
# the headers, keeping generation and runtime ABI sources identical.
text = replace(
    text,
    "using LibRaw_jll\n" => "using LibRaw_jll\n\nconst libraw = LibRaw_jll.libraw_path\n",
)
write(output, text)
