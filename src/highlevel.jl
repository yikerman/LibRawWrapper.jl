"""
Exception with `operation::Symbol`, native `code::Int`, and `message::String`; see [`isfatal`](@ref) for recovery.
"""
struct LibRawError <: Exception
    operation::Symbol
    code::Int
    message::String
end
"""
Display a [`LibRawError`](@ref) with its operation, native code, and message.
"""
Base.showerror(io::IO, e::LibRawError) =
    print(io, "LibRaw ", e.operation, " failed (", e.code, "): ", e.message)
"""
    isfatal(error::LibRawError) -> Bool

Report whether LibRaw classified the error as fatal (`code < -100000`). Managed
calls mark the processor [`Failed`](@ref) on these errors; use [`recycle!`](@ref)
or [`open!`](@ref) before continuing. A nonfatal error still means that the
requested operation did not succeed.

```jldoctest
julia> isfatal(LibRawError(:unpack, -100009, "cancelled"))
true
```

See the [LibRaw C API](https://www.libraw.org/docs/API-C.html) for native error handling.
"""
isfatal(e::LibRawError) = e.code < -100000

# Address individual fields without materializing enormous ABI tuples (notably
# color.curve and maker notes). Layout remains defined by the generated types.
"""
Locate a field using generated ABI offsets without copying large native structs; the caller must keep the owner alive.
"""
function _fieldptr(ptr::Ptr{T}, ::Val{F}) where {T,F}
    i = Base.fieldindex(T, F)
    Ptr{fieldtype(T, i)}(Ptr{UInt8}(ptr) + fieldoffset(T, i))
end
"""
Read one native field without materializing its enclosing ABI struct; the caller preserves the owner.
"""
_load(ptr, field::Val) = unsafe_load(_fieldptr(ptr, field))

"""
    LibRawProcessor(flags::Integer=0)

Allocate a native LibRaw processor in the [`Empty`](@ref) state. `flags` is passed
to `libraw_init`. The object owns the handle and any copied buffer input. Prefer
[`openraw`](@ref) with a do-block for automatic cleanup; manual users must call
[`close!`](@ref), with a finalizer as a fallback. Use one processor per task or
synchronize all access, including closing.

```julia
p = LibRawProcessor()
try
    open!(p, "photo.nef")
    unpack!(p)
    image = postprocess!(p)
finally
    close!(p)
end
```

Direct mutation of `handle` or calls through the raw API bypass the managed
state checks. See [LibRaw initialization](https://www.libraw.org/docs/API-C.html).
"""
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
"""
Return whether the native handle is allocated; `true` also includes `Empty` and `Failed` processors.
"""
Base.isopen(p::LibRawProcessor) = p.state != Closed && p.handle != C_NULL
"""
Release native resources, enter `Closed`, and return `nothing`; repeated calls are harmless and copied results survive.
"""
function Base.close(p::LibRawProcessor)
    if isopen(p)
        GC.@preserve p libraw_close(p.handle)
        p.handle = C_NULL
        _reset!(p)
        p.state = Closed
    end
    nothing
end
"""
Alias for [`close(::LibRawProcessor)`](@ref); release the handle permanently and return `nothing`.
"""
close!(p::LibRawProcessor) = close(p)

"""
Forget Julia-side input, cached sensor metadata, and rendered output after native resources have been released.
"""
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
"""
Reject closed or failed processors before accessing native state.
"""
function _ensure(p::LibRawProcessor)
    isopen(p) || throw(ArgumentError("LibRawProcessor is closed"))
    p.state == Failed &&
        throw(ArgumentError("processor failed; recycle! or reopen it before use"))
    nothing
end
"""
Enforce the permitted lifecycle states before a managed operation reaches the C API.
"""
function _require(p, states...)
    _ensure(p)
    p.state in states ||
        throw(ArgumentError("operation unavailable in processor state $(p.state)"))
end
"""
Require a successfully opened input at any usable stage.
"""
_require_open(p) = _require(p, Opened, Unpacked, Working, Processed)
"""
Require sensor unpacking to have completed, including working or processed stages.
"""
_require_unpacked(p) = _require(p, Unpacked, Working, Processed)

"""
Translate native failures to `LibRawError` and invalidate output after fatal errors; return the processor on success.
"""
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
"""
    recycle!(p::LibRawProcessor) -> LibRawProcessor

Release the current input and native image buffers while keeping the handle for
another file. Reset processing options to the defaults captured at construction,
clear cached metadata/output, and enter [`Empty`](@ref). This also recovers from
[`Failed`](@ref), but a closed processor cannot be recycled. Previously copied
images and snapshots remain usable.

[`open!`](@ref) already recycles before opening a new source; call this explicitly
when releasing the current file without immediately replacing it.
See [LibRaw recycling](https://www.libraw.org/docs/API-CXX.html).
"""
function recycle!(p::LibRawProcessor)
    isopen(p) || throw(ArgumentError("LibRawProcessor is closed"))
    GC.@preserve p begin
        libraw_recycle(p.handle)
        # LibRaw retains output options across recycling. Restore defaults before
        # another open/unpack, where options such as half_size affect geometry.
        unsafe_store!(_fieldptr(p.handle, Val(:params)), p.defaults)
    end
    _reset!(p)
end
"""
    open!(p::LibRawProcessor, source) -> LibRawProcessor

Replace the current input and read its metadata, entering [`Opened`](@ref).
`source` accepts a file path, an `AbstractVector{UInt8}`, or an `IO`. This does
not unpack sensor pixels; call [`unpack!`](@ref) before rendering or sensor access.
The previous input and processing options are reset through [`recycle!`](@ref).

Byte vectors are copied and retained until recycling or closing, so the caller
may modify or discard the original. IO is read from its current position to EOF
and is never closed by this function. Empty buffers and paths containing NUL
are rejected. Native open failures throw [`LibRawError`](@ref).

```julia
p = LibRawProcessor()
try
    open!(p, read("photo.nef"))
    info = metadata(p)           # metadata needs no unpacking
    unpack!(p)
    sensor = sensor_image(p)
finally
    close!(p)
end
```

Wraps `libraw_open_file`/`libraw_open_buffer` from the
[LibRaw C API](https://www.libraw.org/docs/API-C.html).
"""
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

"""
    openraw(source; unpack=true) -> LibRawProcessor
    openraw(f::Function, source; unpack=true)

Create a processor and open a path, byte vector, or IO using [`open!`](@ref).
By default, also unpack sensor data. Use `unpack=false` for metadata or thumbnail
inspection without decoding the full sensor image.

The do-block form returns the block's result and closes the processor even if
the block throws. Without a block, the caller owns the processor and must close
it. Initialization failures always close the new processor. Caller-owned IO
remains open.

```julia
image = openraw("photo.nef") do p
    postprocess!(p; output_type=UInt16)
end
# image.data remains valid here, after p has closed.

info = openraw("photo.nef"; unpack=false) do p
    metadata(p)
end
```
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
"""
    unpack!(p::LibRawProcessor) -> LibRawProcessor

Decode the opened RAW input into native sensor buffers, cache its original
geometry/calibration/CFA layout, and enter [`Unpacked`](@ref). Requires
[`Opened`](@ref); a second unpack without reopening is rejected. This stage is
needed by [`sensor_image`](@ref) and [`process!`](@ref), but not by metadata or
thumbnail inspection. [`openraw`](@ref) performs it by default.

See [`LibRaw::unpack`](https://www.libraw.org/docs/API-CXX.html) and
[`libraw_rawdata_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_rawdata_t).
"""
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
"""
    prepare_image!(p::LibRawProcessor) -> LibRawProcessor

Build LibRaw's four-channel working buffer from unpacked sensor data. Requires
`Unpacked`, `Working`, or `Processed`; enters [`Working`](@ref) and invalidates
the previous processed output. This exposes an intermediate stage for inspection;
normal rendering through [`postprocess!`](@ref) does not require this call.

```julia
openraw("photo.nef") do p
    prepare_image!(p)
    intermediate = working_image(p)
end
```

Wraps `libraw_raw2image`; see the [LibRaw C++ workflow](https://www.libraw.org/docs/API-CXX.html).
"""
function prepare_image!(p::LibRawProcessor)
    _require_unpacked(p)
    GC.@preserve p _check(p, :raw2image, libraw_raw2image(p.handle))
    p.state = Working
    p.output = nothing
    p
end
"""
    working_image(p::LibRawProcessor) -> Array{UInt16,3}

Copy the current four-channel working buffer in `(height, width, 4)` order.
Requires [`Working`](@ref) or [`Processed`](@ref). Its content depends on the
processing stage; it is not the original sensor plane or a formatted output image.
Use [`sensor_image`](@ref) for sensor samples and [`processed_image`](@ref) for
rendered output with its output depth and orientation. The copy survives closing.
"""
function working_image(p::LibRawProcessor)
    _require(p, Working, Processed)
    GC.@preserve p begin
        s = _load(p.handle, Val(:sizes))
        ptr = _load(p.handle, Val(:image))
        _copy_pixels(Ptr{UInt16}(ptr), Int(s.iheight), Int(s.iwidth), 4, Int(s.iwidth)*8)
    end
end
"""
Copy the current 3×4 camera-to-sRGB matrix from [`color_data`](@ref); requires an opened input.
"""
rgb_cam_matrix(p::LibRawProcessor) = color_data(p).rgb_cam
"""
    metadata(p::LibRawProcessor) -> NamedTuple

Return a compact summary for file identification: `make`, `model`, `width`,
`height`, `iso`, `shutter` (seconds), `aperture` (f-number), and `focal_length`
(millimetres). Requires an opened input. Dimensions come from the current
`iwidth`/`iheight`, so they can change with processing; use [`snapshot`](@ref)
for more complete, stage-specific metadata.

```julia
openraw("photo.nef"; unpack=false) do p
    info = metadata(p)
    println(info.make, " ", info.model, " at ISO ", info.iso)
end
```
"""
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
"""
Decode known warning flags while retaining unknown bits so newer native warnings are not silently discarded.
"""
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
"""
    warnings(p::LibRawProcessor) -> ProcessingWarnings

Copy native warning flags for the current input. Requires an opened, usable
processor. Warnings describe recoverable conditions or processing information;
they do not replace exceptions for failed operations. Inspect them after a render
to detect native fallbacks, for example.

```julia
openraw("photo.nef") do p
    image = postprocess!(p)
    report = warnings(p)
    println(report.known, " unknown bits: ", report.unknown_bits)
end
```
"""
function warnings(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _decode_warnings(_load(p.handle, Val(:process_warnings)))
end
