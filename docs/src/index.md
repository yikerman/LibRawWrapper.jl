# LibRawWrapper.jl

`LibRawWrapper` provides two interfaces to LibRaw:

1. `LibRawWrapper.LibRawRaw` contains the generated, low-level C API.
2. `LibRawProcessor` provides a managed Julia workflow with GC-owned results.

## High-level API

```julia
using LibRawWrapper

openraw("photo.nef") do raw
    info = metadata(raw)
    println("$(info.make) $(info.model): $(info.width)×$(info.height)")
    sensor = sensor_image(raw)
    matrix = rgb_cam_matrix(raw) # Julia-owned 3×4 Matrix{Float32}
    rendered = postprocess!(raw; output_type=UInt16, half_size=true)
    pixels = rendered.data # Julia-owned height × width × channels array
end
```

`open!` also accepts a byte vector or IO. The processor retains a copied vector until
`recycle!` or `close!`, so the native reader never references dead Julia memory.
Required operation failures throw `LibRawError` with the LibRaw error code and
message. `close!` is safe to call more than once; `close` is also registered as a
finalizer. See [`ProcessingParams`](@ref) for every rendering keyword and default.

### Lifecycle and ownership

| Operation | Required state | Resulting state |
|:--|:--|:--|
| [`open!`](@ref) | Any except `Closed` | `Opened` |
| [`unpack!`](@ref) | `Opened` | `Unpacked` |
| [`prepare_image!`](@ref) | `Unpacked`, `Working`, `Processed` | `Working` |
| [`process!`](@ref) / [`postprocess!`](@ref) | `Unpacked`, `Working`, `Processed` | `Processed` |
| [`unpack_thumbnail!`](@ref) | Any opened, usable input | Unchanged on success |
| [`recycle!`](@ref) | Any except `Closed` | `Empty` |
| [`close!`](@ref) / [`close`](@ref Base.close(::LibRawProcessor)) | Any | `Closed` |

Metadata access needs an opened input; sensor access needs unpacking; rendered
output access needs a successful render. Fatal native errors enter `Failed`,
which requires recycling or reopening. Invalid lifecycle calls throw
`ArgumentError`. [`warnings`](@ref) reports recoverable native conditions and
processing information separately from exceptions. `isopen(p)` means a handle
exists, so it can be true even for an empty or failed processor.

Use one processor per task or synchronize access. Owned results survive closing,
but the processor itself is mutable and snapshots are not atomic under concurrent
access. `open!` and `recycle!` restore default processing options; repeated renders
apply a complete configuration to the original sensor data.

## Data snapshots

### Why snapshots exist

The underlying LibRaw processor is a mutable, stateful object. Calls such as
`open!`, `unpack!`, `process!`, `recycle!`, and parameter setters mutate shared
`imgdata` fields and allocate or release native buffers. Reading those fields
directly is therefore stage-dependent and has observable side effects through
the processor's lifetime and ownership rules.

`snapshot(p)` copies supported values into Julia-owned structs, arrays, strings,
and dictionaries. The result can be retained after the processor is recycled or
closed. Struct fields cannot be reassigned, but their arrays and dictionaries
remain mutable. The snapshot records the processing stage at which it was taken.

The supported LibRaw aggregates can be copied into Julia-owned
values with `snapshot(p)`, or individually with `image_sizes`, `image_identity`,
`color_data`, `image_other`, `lens_info`, `shooting_info`, `thumbnail_info`, and
`raw_data_info`. For example:

```julia
openraw("photo.nef") do p
    s = snapshot(p)
    println(s.identity.model)
    println(s.color.rgb_cam) # ordinary Julia Matrix{Float32}
    println(s.other.iso_speed)
end
```

These snapshots remain valid after `recycle!(p)` or `close!(p)`. The generated
`LibRawRaw` structs remain available when exact ABI-level access is required.
`sensor_color` holds unpack-time calibration, while `color` reflects the current
stage. `maker_notes` currently holds vendor keys with `nothing` placeholders;
`dng[:entries]` contains copied native DNG color entries, not every DNG tag.

## High-level recipes

The `examples/` directory contains runnable counterparts to the small LibRaw
samples: `identify.jl` (raw-identify), `unprocessed.jl` (unprocessed sensor
and CFA access), `process.jl` (simple_dcraw rendering), `thumbnail.jl`, and
`buffer.jl` (memory input). Run one with `julia --project examples/process.jl
photo.nef`.

The remaining upstream samples exercise APIs that are deliberately not yet
wrapped, such as `open_bayer`, multithreaded rendering, progress callbacks,
and raw text/vendor metadata dumps. They are tracked in `TODO.md` until a
Julia-owned interface can represent them cleanly.

### Inspect a file without retaining native state

```julia
using LibRawWrapper

identify(path) = openraw(path) do p
    snapshot(p)
end

info = identify("photo.nef")
println(info.identity.make, " ", info.identity.model)
println(info.sizes.raw_width, " × ", info.sizes.raw_height)
```

The returned snapshot contains copied values and does not keep the processor
alive.

### Read raw pixels and camera color data

```julia
openraw("photo.nef") do p
    sensor = sensor_image(p; visible=true)
    pixels = sensor.data                       # height × width[/channels]
    camera_matrix = rgb_cam_matrix(p)          # 3 × 4, Float32
    println("first pixel: ", ndims(pixels) == 2 ? pixels[1, 1] : pixels[1, 1, :])
end
```

`sensor_image` copies the unpacked sensor buffer and preserves its CFA layout;
it never invokes `raw2image` or changes the native working image.

### Render a processed image

```julia
openraw("photo.nef") do p
    rendered = postprocess!(p; output_type=UInt8, color_space=SRGB,
        demosaic=AHD, auto_bright=true)
    # `rendered.data` is safe to retain after close! or recycle!.
    println(size(rendered.data), " ", eltype(rendered.data), " ", rendered.metadata)
end
```

The result contains a copied typed array in height × width × channel order and
an `OutputMetadata` value describing the rendering settings. Convert it to the
representation expected by your image writer before encoding a file; Julia's
array storage is not interleaved RGB file order. Color space and gamma are
separate settings; choosing `SRGB` does not itself select the sRGB transfer curve.

### Load from a memory buffer

```julia
bytes = read("photo.nef")
openraw(bytes) do p
    println(metadata(p))
end
```

`open!` copies the input vector into the processor, ensuring it remains valid
for LibRaw’s native reader.

### Extract a thumbnail

```julia
openraw("photo.nef"; unpack=false) do p
    thumb = extract_thumbnail!(p)
    thumb === nothing && error("file has no readable thumbnail")
    width, height = thumb isa JPEGThumbnail ?
        (thumb.width, thumb.height) : (size(thumb.data, 2), size(thumb.data, 1))
    println("thumbnail: ", width, " × ", height)
    write("photo.thumbnail", thumb.data)
end
```

Some formats legitimately have no thumbnail. That optional stage can fail while
the main RAW image remains processable.
JPEG dimensions may be zero; decode the JPEG bytes if dimensions are needed.
The recipe writes the payload as-is: JPEG bytes are encoded, whereas bitmap
pixels need an image encoder to produce a standard image file.

### Reuse one processor for multiple files

```julia
openraw("one.nef"; unpack=false) do p
    for path in ["one.nef", "two.nef"]
        open!(p, path)
        unpack!(p)
        println(metadata(p).model)
    end
end
```

`recycle!` releases LibRaw’s stage buffers while keeping the Julia processor
object available for the next input.

### Handle failures explicitly

```julia
try
    openraw("missing.nef") do _
    end
catch e
    if e isa LibRawError
        println("operation $(e.operation) failed with code $(e.code): $(e.message)")
    else
        rethrow()
    end
end
```

High-level operations throw `LibRawError`; the raw API remains available when
callers need to inspect and handle numeric LibRaw return codes themselves.

## Raw C API

The generated functions remain available for code that needs exact LibRaw
semantics or public C structs:

```julia
using LibRawWrapper

handle = libraw_init(0)
handle == C_NULL && error("could not initialize LibRaw")
try
    code = libraw_open_file(handle, "photo.nef")
    code == 0 || error(unsafe_string(libraw_strerror(code)))
    code = libraw_unpack(handle)
    code == 0 || error(unsafe_string(libraw_strerror(code)))

    data = unsafe_load(handle)
    println("raw dimensions: ", data.sizes.raw_width, "×", data.sizes.raw_height)
finally
    libraw_close(handle)
end
```

The raw layer exposes all generated `libraw_*` functions, enums, and structs.
Pointers and buffers returned by it follow the C API lifetime rules; use the
high-level layer when copied Julia ownership is preferred.


More complete workflows are available in [`examples/metadata.jl`](https://github.com/yikerman/LibRawWrapper.jl/blob/main/examples/metadata.jl), [`examples/process.jl`](https://github.com/yikerman/LibRawWrapper.jl/blob/main/examples/process.jl), and [`examples/buffer.jl`](https://github.com/yikerman/LibRawWrapper.jl/blob/main/examples/buffer.jl). They follow the same open, unpack, inspect/process, and close sequence as the LibRaw distribution samples.
