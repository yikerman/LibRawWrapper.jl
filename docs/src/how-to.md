# How-to guides

These recipes assume `using LibRawWrapper`. For setup, see the
[tutorial](tutorial.md).

```@contents
Pages = ["how-to.md"]
Depth = 2
```

## Inspect metadata without decoding pixels

Use `unpack=false` to skip sensor decoding:

```julia
info = openraw("photo.nef"; unpack=false) do raw
    snapshot(raw)
end
println(info.identity.make, " ", info.identity.model)
println(info.sizes.raw_width, " × ", info.sizes.raw_height)
println("ISO ", info.other.iso_speed)
```

For a smaller summary, use [`metadata`](@ref). Individual accessors such as
[`lens_info`](@ref) and [`image_other`](@ref) copy only the corresponding group
of fields. See [What a snapshot records](@ref) for coverage and stage differences.

## Render with explicit settings

Reuse a [`ProcessingParams`](@ref) value across files. These settings produce
16-bit output with camera white balance, linear gamma, and automatic brightness
disabled:

```julia
options = ProcessingParams(
    output_type=UInt16,
    white_balance=CameraWB(),
    color_space=SRGB,
    gamma=(1, 1),
    auto_bright=false,
)
image = openraw("photo.nef") do raw
    postprocess!(raw, options)
end
println(size(image.data), " ", eltype(image.data))
```

For a single render, pass the same options as keywords to [`postprocess!`](@ref).
Use `gamma=(1/2.4, 12.92)` with `color_space=SRGB` to request LibRaw's sRGB
curve. `CameraWB()` can fall back to automatic balance when camera coefficients
are missing.

Repeated calls to `postprocess!` reuse the decoded sensor data and return
separate pixel arrays.

## [Write an RGB image to disk](@id write-rgb)

PPM stores each pixel's RGB bytes consecutively:

```julia
openraw("photo.nef") do raw
    image = postprocess!(raw; output_type=UInt8, color_space=SRGB)
    height, width, channels = size(image.data)
    channels == 3 || error("PPM output requires three channels")
    open("processed.ppm", "w") do io
        write(io, "P6\n$(width) $(height)\n255\n")
        for row in 1:height, col in 1:width
            write(io, image.data[row, col, 1])
            write(io, image.data[row, col, 2])
            write(io, image.data[row, col, 3])
        end
    end
end
```

For other formats, convert `image.data` to your image encoder's expected
representation.

The repository also provides this workflow as a script:

```sh
julia --project examples/process.jl photo.nef processed.ppm
```

## Read sensor samples and identify their CFA channels

Copy the visible sensor region for custom processing. On a CFA sensor, use
[`color_index`](@ref) to identify a sample's channel:

```julia
sensor, calibration = openraw("photo.nef") do raw
    sensor_image(raw; visible=true), color_data(raw)
end
println(size(sensor.data))
println(calibration.rgb_cam)
if sensor.layout isa CFALayout
    channel = color_index(sensor, 1, 1)
    println("first sample: ", sensor.data[1, 1])
    println("channel: ", sensor.layout.channel_labels[channel])
    println("CFA tile: ", cfa_pattern(sensor))
end
```

Use `visible=false`, the default, to include sensor margins. Use
[`color_indices`](@ref) if you need a full-size channel map for a mask. For
monochrome or multichannel layouts, access the samples without CFA lookup.
Some geometries cannot be exposed by `sensor_image` and raise `ArgumentError`.
Native rendering may still work for those files.

## Open bytes or an IO stream

Pass a byte vector when the file is already in memory:

```julia
bytes = read("photo.nef")
info = openraw(bytes; unpack=false) do raw
    metadata(raw)
end
```

For an IO stream, position it at the start of the RAW data before opening:

```julia
open("photo.nef") do io
    info = openraw(io; unpack=false) do raw
        metadata(raw)
    end
    println(info.model)
    @assert isopen(io)
end
```

The wrapper reads IO from its current position to EOF and copies the input
bytes. Closing the processor leaves the stream open.

## Extract an embedded preview

Skip sensor unpacking and branch on the preview type:

```julia
thumb = openraw("photo.nef"; unpack=false) do raw
    extract_thumbnail!(raw)
end
if thumb === nothing
    println("This file has no embedded preview")
elseif thumb isa JPEGThumbnail
    write("preview.jpg", thumb.data)
    println("Wrote preview.jpg")
elseif thumb isa BitmapThumbnail
    pixels = thumb.data
    println("Bitmap preview: ", size(pixels))
    # Pass pixels to an image encoder to save a file.
end
```

Select a preview with the one-based `index` keyword of
[`extract_thumbnail!`](@ref). A missing thumbnail returns `nothing`, while
invalid indices and other errors throw. JPEG XL and H.265 previews require
the raw API.

## Process several files with one processor

[`open!`](@ref) recycles the previous input, so one processor can handle a batch:

```julia
paths = ["one.nef", "two.nef"]
options = ProcessingParams(output_type=UInt8, half_size=true)
images = ProcessedImage[]
raw = LibRawProcessor()
try
    for path in paths
        open!(raw, path)
        unpack!(raw)
        push!(images, postprocess!(raw, options))
    end
finally
    close!(raw)
end
```

`images` remains usable after closing. For large batches, write or consume each
image inside the loop instead of retaining all arrays. Call [`recycle!`](@ref)
if you want to release the current file before the next input is available.

## [Handle failures and inspect warnings](@id handle-failures)

Native failures throw [`LibRawError`](@ref). Processing warnings are available
through [`warnings`](@ref):

```julia
try
    openraw("photo.nef") do raw
        image = postprocess!(raw)
        report = warnings(raw)
        println("warnings: ", report.known)
        println("unknown warning bits: ", report.unknown_bits)
    end
catch err
    if err isa LibRawError
        println("$(err.operation) failed ($(err.code)): $(err.message)")
    else
        rethrow()
    end
end
```

For a manually managed processor, [`isfatal`](@ref) identifies errors that
invalidate its state. Reopen the source or recycle the processor after a fatal
failure. Invalid call order raises `ArgumentError` before calling LibRaw.

## [Call the raw C API](@id raw-api)

Use a separate native handle when you need an operation outside the managed
API. Check return codes and release the handle in `finally`:

```julia
handle = libraw_init(0)
handle == C_NULL && error("could not initialize LibRaw")
try
    code = libraw_open_file(handle, "photo.nef")
    code == 0 || error(unsafe_string(libraw_strerror(code)))
    code = libraw_unpack(handle)
    code == 0 || error(unsafe_string(libraw_strerror(code)))
    width = libraw_get_raw_width(handle)
    height = libraw_get_raw_height(handle)
    println("raw dimensions: ", width, " × ", height)
finally
    libraw_close(handle)
end
```

Consult the [LibRaw C API](https://www.libraw.org/docs/API-C.html) for the native
functions and their lifetime rules. Generated `libraw_*` names are re-exported
by `LibRawWrapper`. Other raw names are available through
`LibRawWrapper.LibRawRaw`.
