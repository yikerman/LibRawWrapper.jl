# LibRaw stores pixels in row-major order with a byte pitch. Copy directly into
# Julia's column-major arrays, including crops, without retaining native views.
"""
Copy a pitched native pixel buffer into Julia row/column/channel indexing, optionally
cropping while copying. Validate dimensions and byte pitch before pointer reads.
Callers must provide valid storage and ascending in-bounds crop ranges and keep
the native owner alive. Used by sensor images, working buffers, rendered images,
and bitmap thumbnails.
"""
function _copy_pixels(
    ptr::Ptr{T},
    h::Int,
    w::Int,
    channels::Int,
    pitch::Int;
    rows = 1:h,
    cols = 1:w,
) where {T<:Union{UInt8,UInt16,Float32}}
    ptr != C_NULL || throw(ArgumentError("image buffer is NULL"))
    h > 0 && w > 0 && channels in (1, 3, 4) ||
        throw(ArgumentError("invalid image dimensions or channels"))
    rowbytes = Base.checked_mul(Base.checked_mul(w, channels), sizeof(T))
    pitch >= rowbytes && pitch % sizeof(T) == 0 ||
        throw(ArgumentError("invalid image row pitch"))
    Base.checked_mul(h, pitch)
    isempty(rows) ||
        (first(rows) >= 1 && last(rows) <= h) ||
        throw(ArgumentError("invalid row crop"))
    isempty(cols) ||
        (first(cols) >= 1 && last(cols) <= w) ||
        throw(ArgumentError("invalid column crop"))
    isempty(rows) || isempty(cols) ? throw(ArgumentError("empty image crop")) : nothing
    data = Array{T}(undef, length(rows), length(cols), channels)
    stride = pitch ÷ sizeof(T)
    for ch = 1:channels, (x, col) in enumerate(cols), (y, row) in enumerate(rows)
        @inbounds data[y, x, ch] = unsafe_load(ptr, (row-1)*stride + (col-1)*channels + ch)
    end
    data
end

"""
Internal explanation for sensor geometries that cannot be exposed as a rectangular high-level image.
"""
struct UnsupportedSensorLayout <: SensorLayout
    reason::String
end

"""
Reduce a periodic CFA tile to its smallest repeating rectangle so callers need not interpret a redundant native mask.
"""
function _minimal_pattern(tile::Matrix{UInt8})
    h, w = size(tile)
    for rows = 1:h, cols = 1:w
        h % rows == 0 && w % cols == 0 || continue
        all(tile[r, c] == tile[mod1(r, rows), mod1(c, cols)] for r = 1:h, c = 1:w) ||
            continue
        return tile[1:rows, 1:cols]
    end
    copy(tile)
end

"""
Classify the unpacked sensor and derive a CFA tile aligned to the full sensor
origin. LibRaw COLOR coordinates are visible-relative, so compensate for margins
before caching the pattern. Preserve unsupported-layout reasons for a later
`sensor_image` error without preventing metadata access or native rendering.
"""
function _sensor_layout(p)
    GC.@preserve p begin
        id = _load(p.handle, Val(:idata))
        labels = _chars(id.cdesc)
        raw = _fieldptr(p.handle, Val(:rawdata))
        flat =
            _load(raw, Val(:raw_image)) != C_NULL || _load(raw, Val(:float_image)) != C_NULL
        flat || return MultichannelLayout(labels)
        id.filters == 0 && return id.colors == 1 ? MonochromeLayout() :
               UnsupportedSensorLayout("single-plane data has no supported CFA mapping")
        io = _load(raw, Val(:ioparams))
        io.fuji_width != 0 && return UnsupportedSensorLayout(
            "Fuji rotated sensor geometry is not a rectangular CFA layout",
        )
        h, w =
            id.filters == 9 ? (6, 6) :
            id.filters == 1 ? (16, 16) : id.filters >= 1000 ? (8, 2) : (0, 0)
        h == 0 &&
            return UnsupportedSensorLayout("unsupported CFA filter code $(id.filters)")
        s = p.sensor_geometry::ImageSizes
        # COLOR takes visible-relative coordinates. Positive modulo avoids
        # negative C remainders in special patterns while preserving phase.
        tile = [
            UInt8(
                libraw_COLOR(
                    p.handle,
                    mod(r-1-s.top_margin, h),
                    mod(c-1-s.left_margin, w),
                ) + 1,
            ) for r = 1:h, c = 1:w
        ]
        all(x -> 1 <= x <= length(labels), tile) ||
            return UnsupportedSensorLayout("CFA channel has no label")
        pattern = _minimal_pattern(tile)
        kind = id.filters == 9 ? XTrans : size(pattern) == (2, 2) ? Bayer : PeriodicCFA
        CFALayout(kind, pattern, labels)
    end
end

"""
Select the active native sensor pointer and channel count, rejecting ambiguous or absent buffers before copying.
"""
function _sensor_buffer(raw::Ptr{libraw_rawdata_t})
    candidates = (
        (Val(:raw_image), UInt16, 1),
        (Val(:color3_image), UInt16, 3),
        (Val(:color4_image), UInt16, 4),
        (Val(:float_image), Float32, 1),
        (Val(:float3_image), Float32, 3),
        (Val(:float4_image), Float32, 4),
    )
    active = filter(x -> _load(raw, x[1]) != C_NULL, candidates)
    length(active) == 1 || throw(ArgumentError("expected exactly one active sensor buffer"))
    field, T, channels = only(active)
    Ptr{T}(_load(raw, field)), channels
end

"""
    sensor_image(p::LibRawProcessor; visible=false) -> SensorImage

Copy unpacked sensor samples for calibration or custom image processing. Requires
`Unpacked`, `Working`, or `Processed`. A single-plane sensor yields a matrix,
and multichannel data yields `(height, width, channels)`. Samples are `UInt16` or
`Float32`, depending on the active native buffer. This copy adds no demosaicing,
black subtraction, rotation, or tone mapping. The camera or decoder may already
have corrected the samples, including black subtraction. LibRaw's default
unpacking also converts floating-point RAW data to integers when applicable.

With `visible=true`, remove margins using the geometry saved during unpacking.
The result retains that geometry and a one-based `origin` in the full sensor,
so CFA lookup stays aligned after cropping. Data and layout are independent
copies. Unsupported layouts, including rotated Fuji geometry, throw
`ArgumentError`. They may still be renderable through [`postprocess!`](@ref).

```julia
sensor = openraw("photo.nef") do p
    sensor_image(p; visible=true)
end
if sensor.layout isa CFALayout
    channel = color_index(sensor, 1, 1)
    println(sensor.layout.channel_labels[channel])
end
```

See [`libraw_rawdata_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_rawdata_t).
"""
function sensor_image(p::LibRawProcessor; visible::Bool = false)
    _require_unpacked(p)
    layout = p.sensor_layout
    layout isa UnsupportedSensorLayout && throw(ArgumentError(layout.reason))
    layout isa SensorLayout || throw(ArgumentError("sensor layout is unavailable"))
    s = p.sensor_geometry::ImageSizes
    rows = visible ? ((s.top_margin+1):(s.top_margin+s.height)) : (1:s.raw_height)
    cols = visible ? ((s.left_margin+1):(s.left_margin+s.width)) : (1:s.raw_width)
    data = GC.@preserve p begin
        ptr, channels = _sensor_buffer(_fieldptr(p.handle, Val(:rawdata)))
        values = _copy_pixels(
            ptr,
            s.raw_height,
            s.raw_width,
            channels,
            s.raw_pitch;
            rows,
            cols,
        )
        channels == 1 ? dropdims(values; dims = 3) : values
    end
    SensorImage(data, deepcopy(layout), s, (first(rows), first(cols)))
end

"""
    cfa_pattern(sensor::SensorImage)

Return a copied tile of one-based channel indices aligned with the first pixel
of this sensor snapshot, including its crop origin. Return `nothing` for a
non-CFA layout. Indices address `sensor.layout.channel_labels`, not a fixed RGB
ordering. Separate green channels may have different indices. See
[`color_index`](@ref) for per-pixel lookup.
"""
cfa_pattern(s::SensorImage) = nothing
function cfa_pattern(s::SensorImage{T,N,CFALayout}) where {T,N}
    pattern = s.layout.pattern
    h, w = size(pattern)
    [pattern[mod1(r+s.origin[1]-1, h), mod1(c+s.origin[2]-1, w)] for r = 1:h, c = 1:w]
end
"""
    color_index(sensor::SensorImage, row::Integer, col::Integer) -> UInt8

Find the CFA channel at a one-based position in `sensor.data`. Account for the
snapshot's full-sensor origin, so the same physical pixel keeps its channel after
cropping. Throws `BoundsError` outside the data and `ArgumentError` for non-CFA
layouts. The result indexes `sensor.layout.channel_labels`.

```julia
openraw("photo.nef") do p
    sensor = sensor_image(p; visible=true)
    if sensor.layout isa CFALayout
        label = sensor.layout.channel_labels[color_index(sensor, 1, 1)]
        println("top-left channel: ", label)
    end
end
```
"""
function color_index(s::SensorImage, row::Integer, col::Integer)
    throw(ArgumentError("color_index requires a CFA sensor image"))
end
function color_index(s::SensorImage{T,N,CFALayout}, row::Integer, col::Integer) where {T,N}
    1 <= row <= size(s.data, 1) && 1 <= col <= size(s.data, 2) ||
        throw(BoundsError(s.data, (row, col)))
    pattern = s.layout.pattern
    pattern[
        mod1(row+s.origin[1]-1, size(pattern, 1)),
        mod1(col+s.origin[2]-1, size(pattern, 2)),
    ]
end
"""
    color_indices(sensor::SensorImage) -> Matrix{UInt8}

Allocate a channel-index map matching the sensor's rows and columns, using
[`color_index`](@ref) at every pixel. Useful for channel masks in custom sensor
processing, for example `green = color_indices(sensor) .== 2` when channel 2 is
green. Requires a CFA layout. Use [`cfa_pattern`](@ref) when only the small
repeating tile is needed, avoiding a full-image allocation.
"""
color_indices(s::SensorImage) =
    throw(ArgumentError("color_indices requires a CFA sensor image"))
function color_indices(s::SensorImage{T,N,CFALayout}) where {T,N}
    [color_index(s, r, c) for r in axes(s.data, 1), c in axes(s.data, 2)]
end
