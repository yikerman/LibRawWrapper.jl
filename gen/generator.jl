using Clang.Generators
using LibRaw_jll
using Pkg.Artifacts
using Base.BinaryPlatforms
cd(@__DIR__)

const TARGETS = [
    "aarch64-apple-darwin20",
    "aarch64-linux-gnu",
    "i686-w64-mingw32",
    "x86_64-apple-darwin14",
    "x86_64-linux-gnu",
    "x86_64-w64-mingw32",
]

options = load_options(joinpath(@__DIR__, "generator.toml"))
artifact_toml = joinpath(dirname(pathof(LibRaw_jll)), "..", "Artifacts.toml")
output_dir = joinpath(@__DIR__, "..", "src", "bindings")
mkpath(output_dir)

function normalize!(text)
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
    return text
end

for triple in TARGETS
    platform = parse(Platform, triple)
    meta = artifact_meta("LibRaw", artifact_toml; platform)
    meta === nothing && error("LibRaw_jll has no artifact for $triple")
    ensure_artifact_installed(meta["git-tree-sha1"], meta, artifact_toml; platform)
    include_dir = joinpath(artifact_path(Base.SHA1(meta["git-tree-sha1"])), "include")
    header = joinpath(include_dir, "libraw", "libraw.h")
    args = get_default_args(triple)
    append!(args, ["-x", "c", "-std=c11", "-I$include_dir"])
    target_options = deepcopy(options)
    target_options["general"]["output_file_path"] = joinpath(output_dir, "$triple.jl")
    target_options["general"]["use_deterministic_symbol"] = true
    ctx = create_context([header], args, target_options)
    build!(ctx)
    output = target_options["general"]["output_file_path"]
    write(output, normalize!(read(output, String)))
    @info "Generated" triple output
end
