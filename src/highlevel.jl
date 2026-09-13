"""Exception carrying a failed LibRaw operation, return code, and message."""
struct LibRawError <: Exception
    operation::Symbol
    code::Int
    message::String
end
Base.showerror(io::IO, e::LibRawError) =
    print(io, "LibRaw ", e.operation, " failed (", e.code, "): ", e.message)
isfatal(e::LibRawError) = e.code < -100000

# Address individual fields without materializing enormous ABI tuples (notably
# color.curve and maker notes). Layout remains defined by the generated types.
function _fieldptr(ptr::Ptr{T}, ::Val{F}) where {T,F}
    i = Base.fieldindex(T, F)
    Ptr{fieldtype(T, i)}(Ptr{UInt8}(ptr) + fieldoffset(T, i))
end
_load(ptr, field::Val) = unsafe_load(_fieldptr(ptr, field))

"""Managed LibRaw resource. Use one processor per task, or synchronize all access."""
mutable struct LibRawProcessor
    handle::Ptr{libraw_data_t}
    input::Union{Nothing,Vector{UInt8}}
    state::ProcessorState
    thumbnail_ready::Bool
    sensor_geometry::Union{Nothing,ImageSizes}
    sensor_color::Union{Nothing,ColorData}
    sensor_layout::Union{Nothing,SensorLayout}
    defaults::libraw_output_params_t
    output::Union{Nothing,OutputMetadata}
end

function LibRawProcessor(flags::Integer = 0)
    handle = libraw_init(Cuint(flags))
    handle == C_NULL && throw(LibRawError(:init, -100007, "libraw_init returned NULL"))
    p = LibRawProcessor(
        handle,
        nothing,
        Empty,
        false,
        nothing,
        nothing,
        nothing,
        _load(handle, Val(:params)),
        nothing,
    )
    finalizer(close, p)
    p
end
Base.isopen(p::LibRawProcessor) = p.state != Closed && p.handle != C_NULL
function Base.close(p::LibRawProcessor)
    if isopen(p)
        GC.@preserve p libraw_close(p.handle)
        p.handle = C_NULL
        _reset!(p)
        p.state = Closed
    end
    nothing
end
"""Close a processor and release its native LibRaw handle."""
close!(p::LibRawProcessor) = close(p)

function _reset!(p)
    p.input = nothing
    p.state = Empty
    p.thumbnail_ready = false
    p.sensor_geometry = nothing
    p.sensor_color = nothing
    p.sensor_layout = nothing
    p.output = nothing
    p
end
function _ensure(p::LibRawProcessor)
    isopen(p) || throw(ArgumentError("LibRawProcessor is closed"))
    p.state == Failed &&
        throw(ArgumentError("processor failed; recycle! or reopen it before use"))
    nothing
end
function _require(p, states...)
    _ensure(p)
    p.state in states ||
        throw(ArgumentError("operation unavailable in processor state $(p.state)"))
end
_require_open(p) = _require(p, Opened, Unpacked, Working, Processed)
_require_unpacked(p) = _require(p, Unpacked, Working, Processed)

function _check(p, op, code)
    if code != 0
        e = LibRawError(op, Int(code), unsafe_string(libraw_strerror(code)))
        if isfatal(e)
            p.state = Failed
            p.thumbnail_ready = false
            p.output = nothing
        end
        throw(e)
    end
    p
end
"""Recycle native buffers and reset a processor for another input."""
function recycle!(p::LibRawProcessor)
    isopen(p) || throw(ArgumentError("LibRawProcessor is closed"))
    GC.@preserve p libraw_recycle(p.handle)
    _reset!(p)
end
"""Open a RAW file path in an existing processor."""
function open!(p::LibRawProcessor, path::AbstractString)
    occursin('\0', path) && throw(ArgumentError("path contains a NUL byte"))
    recycle!(p)
    GC.@preserve p _check(p, :open_file, libraw_open_file(p.handle, path))
    p.state = Opened
    p
end
function open!(p::LibRawProcessor, bytes::AbstractVector{UInt8})
    data = collect(bytes)
    isempty(data) && throw(ArgumentError("input buffer is empty"))
    recycle!(p)
    p.input = data
    GC.@preserve p data _check(
        p,
        :open_buffer,
        libraw_open_buffer(p.handle, pointer(data), length(data)),
    )
    p.state = Opened
    p
end
open!(p::LibRawProcessor, io::IO) = open!(p, read(io))

"""Open a path, byte vector, or IO; unpack by default. The do-block form always closes.
Caller-owned IO is read from its current position and is never closed.
"""
function openraw(source; unpack::Bool = true)
    p = LibRawProcessor()
    try
        open!(p, source)
        unpack && unpack!(p)
        p
    catch
        close(p)
        rethrow()
    end
end
function openraw(f::Function, source; kwargs...)
    p = openraw(source; kwargs...)
    try
        f(p)
    finally
        close(p)
    end
end
"""Unpack sensor data and cache its geometry and CFA description."""
function unpack!(p::LibRawProcessor)
    _require(p, Opened)
    GC.@preserve p _check(p, :unpack, libraw_unpack(p.handle))
    p.state = Unpacked
    try
        p.sensor_geometry = image_sizes(p)
        p.sensor_color = color_data(p)
        p.sensor_layout = _sensor_layout(p)
    catch
        p.state = Failed
        rethrow()
    end
    p
end
"""Convert unpacked data to LibRaw's working image buffer."""
function prepare_image!(p::LibRawProcessor)
    _require_unpacked(p)
    GC.@preserve p _check(p, :raw2image, libraw_raw2image(p.handle))
    p.state = Working
    p.output = nothing
    p
end
"""Copy the working image buffer into a Julia-owned array."""
function working_image(p::LibRawProcessor)
    _require(p, Working, Processed)
    GC.@preserve p begin
        s = _load(p.handle, Val(:sizes))
        ptr = _load(p.handle, Val(:image))
        _copy_pixels(Ptr{UInt16}(ptr), Int(s.iheight), Int(s.iwidth), 4, Int(s.iwidth)*8)
    end
end
"""Return the copied 3×4 camera-to-sRGB matrix."""
rgb_cam_matrix(p::LibRawProcessor) = color_data(p).rgb_cam
function metadata(p::LibRawProcessor)
    i, s, o = image_identity(p), image_sizes(p), image_other(p)
    (
        make = i.make,
        model = i.model,
        width = s.iwidth,
        height = s.iheight,
        iso = Float64(o.iso_speed),
        shutter = Float64(o.shutter),
        aperture = Float64(o.aperture),
        focal_length = Float64(o.focal_length),
    )
end
function _decode_warnings(bits::UInt32)
    known = LibRawRaw.LibRaw_warnings[]
    remaining = bits
    for name in names(LibRawRaw; all = true)
        startswith(String(name), "LIBRAW_WARN_") || continue
        value = getfield(LibRawRaw, name)
        value isa LibRawRaw.LibRaw_warnings || continue
        mask = UInt32(value)
        if mask != 0 && bits & mask == mask
            push!(known, value)
            remaining &= ~mask
        end
    end
    sort!(unique!(known); by = UInt32)
    ProcessingWarnings(known, remaining)
end
function warnings(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _decode_warnings(_load(p.handle, Val(:process_warnings)))
end
