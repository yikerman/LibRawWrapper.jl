"""
Store a value after conversion to the generated native field type; the caller preserves the owner.
"""
function _setfield!(ptr, field::Val, value)
    dest = _fieldptr(ptr, field)
    unsafe_store!(dest, convert(eltype(typeof(dest)), value))
end

"""
Apply one white-balance strategy after defaults are restored, preventing mutually exclusive flags from accumulating.
"""
_apply_wb!(params, ::DaylightWB) = nothing
_apply_wb!(params, ::CameraWB) = _setfield!(params, Val(:use_camera_wb), 1)
_apply_wb!(params, ::AutoWB) = _setfield!(params, Val(:use_auto_wb), 1)
_apply_wb!(params, wb::CustomWB) = _setfield!(params, Val(:user_mul), wb.coefficients)

"""
Replace all native output options from a validated configuration and return matching Julia output metadata.
"""
function _apply_params!(p, options::ProcessingParams{T}) where {T}
    params = _fieldptr(p.handle, Val(:params))
    # Reset the entire default record, including mutually exclusive WB flags and
    # gamma's derived coefficients, so repeated renders cannot inherit options.
    unsafe_store!(params, p.defaults)
    _apply_wb!(params, options.white_balance)
    _setfield!(params, Val(:output_bps), 8*sizeof(T))
    _setfield!(params, Val(:output_color), Int(options.color_space))
    _setfield!(params, Val(:user_qual), Int(options.demosaic))
    _setfield!(params, Val(:half_size), options.half_size)
    _setfield!(params, Val(:user_flip), Int(options.orientation))
    _setfield!(params, Val(:bright), options.brightness)
    _setfield!(params, Val(:no_auto_bright), !options.auto_bright)
    _setfield!(params, Val(:highlight), Int(options.highlights))
    gamma = isnothing(options.gamma) ? p.defaults.gamm[1:2] : options.gamma
    _setfield!(params, Val(:gamm), (gamma..., 0.0, 0.0, 0.0, 0.0))
    OutputMetadata(options.color_space, gamma, options.orientation, options.half_size)
end

"""
    process!(p::LibRawProcessor; kwargs...) -> LibRawProcessor
    process!(p::LibRawProcessor, params::ProcessingParams) -> LibRawProcessor

Run LibRaw's rendering pipeline on unpacked data and retain the native result.
Requires `Unpacked`, `Working`, or `Processed`; enters [`Processed`](@ref) on
success. Pass either a complete [`ProcessingParams`](@ref) value or its keyword
options. Each call restores native defaults before applying the supplied options
and rerenders from the original sensor data, making repeated configurations
independent.

Use this when rendering and copying are separate steps; [`postprocess!`](@ref)
combines them. Native failures throw [`LibRawError`](@ref); fatal failures require
recycling or reopening before further work.

```julia
openraw("photo.nef") do p
    process!(p; half_size=true, white_balance=CameraWB())
    report = warnings(p)
    image = processed_image(p)
end
```

Wraps `libraw_dcraw_process`; see [LibRaw processing](https://www.libraw.org/docs/API-CXX.html#dcraw_process).
"""
function process!(p::LibRawProcessor, params::ProcessingParams; kwargs...)
    isempty(kwargs) ||
        throw(ArgumentError("use either ProcessingParams or keyword options"))
    _require_unpacked(p)
    p.output = nothing
    p.state = Unpacked
    GC.@preserve p begin
        metadata = _apply_params!(p, params)
        _check(p, :process, libraw_dcraw_process(p.handle))
        p.output = metadata
        p.state = Processed
    end
    p
end
process!(p::LibRawProcessor; kwargs...) = process!(p, ProcessingParams(; kwargs...))

"""
Validate a native bitmap payload against its dimensions and bit depth before copying samples into a Julia array.
"""
function _bitmap(ptr::Ptr{UInt8}, width, height, channels, bits, nbytes)
    bits in (8, 16) || throw(ArgumentError("unsupported bitmap bit depth: $bits"))
    T = bits == 8 ? UInt8 : UInt16
    pitch = Base.checked_mul(Base.checked_mul(width, channels), sizeof(T))
    nbytes == Base.checked_mul(height, pitch) ||
        throw(ArgumentError("bitmap payload size disagrees with dimensions"))
    _copy_pixels(Ptr{T}(ptr), height, width, channels, pitch)
end

"""
Copy a native image or thumbnail into owned Julia storage and always free the temporary native allocation, including on errors.
"""
function _memory_image(p, op, maker; thumbnail::Bool = false)
    GC.@preserve p begin
        err = Ref{Cint}(0)
        img = maker(p.handle, err)
        if img == C_NULL
            _check(p, op, err[] == 0 ? -1 : err[])
        end
        try
            _check(p, op, err[])
            header = unsafe_load(img)
            h, w, c = Int(header.height), Int(header.width), Int(header.colors)
            bits, n = Int(header.bits), Int(header.data_size)
            data = Ptr{UInt8}(_fieldptr(img, Val(:data)))
            if header.type == LibRawRaw.LIBRAW_IMAGE_JPEG && thumbnail
                JPEGThumbnail(copy(unsafe_wrap(Vector{UInt8}, data, n; own = false)), w, h)
            elseif header.type == LibRawRaw.LIBRAW_IMAGE_BITMAP
                pixels = _bitmap(data, w, h, c, bits, n)
                thumbnail ? BitmapThumbnail(pixels) :
                ProcessedImage(pixels, p.output::OutputMetadata)
            else
                throw(
                    ArgumentError("unsupported LibRaw memory image format: $(header.type)"),
                )
            end
        finally
            libraw_dcraw_clear_mem(img)
        end
    end
end

"""
    processed_image(p::LibRawProcessor) -> ProcessedImage

Copy the last successful render without running the pipeline again. Requires
[`Processed`](@ref); returns an owned `(height, width, channels)` array with
`UInt8` or `UInt16` samples and its [`OutputMetadata`](@ref). Every call allocates
a new copy that remains valid after recycling or closing the processor.

See [`process!`](@ref) for a two-step example and
[`libraw_processed_image_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_processed_image_t)
for the native representation.
"""
function processed_image(p::LibRawProcessor)
    _require(p, Processed)
    _memory_image(p, :make_mem_image, libraw_dcraw_make_mem_image)
end
"""
    postprocess!(p::LibRawProcessor; kwargs...) -> ProcessedImage
    postprocess!(p::LibRawProcessor, params::ProcessingParams{T}) -> ProcessedImage{T}

Render and copy a Julia-owned image by combining [`process!`](@ref) and
[`processed_image`](@ref). Sensor unpacking must already have completed. Choose
options through [`ProcessingParams`](@ref) or keywords, not both. The processor
remains `Processed`, and the returned image can outlive it.

```julia
image = openraw("photo.nef") do p
    postprocess!(p; output_type=UInt16, white_balance=CameraWB(),
        gamma=(1, 1), auto_bright=false)
end
pixels = image.data  # height × width × channels; UInt16, linear gamma
```
"""
function postprocess!(p::LibRawProcessor, params::ProcessingParams{T}; kwargs...) where {T}
    process!(p, params; kwargs...)
    processed_image(p)::ProcessedImage{T}
end
postprocess!(p::LibRawProcessor; kwargs...) = postprocess!(p, ProcessingParams(; kwargs...))

"""
    unpack_thumbnail!(p::LibRawProcessor, index=nothing) -> LibRawProcessor

Load an embedded preview without requiring sensor unpacking. Requires an opened
input and leaves its main lifecycle state unchanged. `index=nothing` uses
LibRaw's default thumbnail selection; explicit indices are **one-based** and
checked against the native thumbnail list. Call [`thumbnail`](@ref) to copy it,
or [`extract_thumbnail!`](@ref) for the combined operation.

Missing thumbnails throw `LibRawError` here. See
[LibRaw thumbnail unpacking](https://www.libraw.org/docs/API-CXX.html#unpack_thumb).
"""
function unpack_thumbnail!(p::LibRawProcessor, index::Union{Nothing,Integer} = nothing)
    _require_open(p)
    GC.@preserve p begin
        if !isnothing(index)
            list = _load(p.handle, Val(:thumbs_list))
            1 <= index <= Int(list.thumbcount) <= length(list.thumblist) ||
                throw(ArgumentError("thumbnail index out of bounds"))
        end
        p.thumbnail_ready = false
        code =
            isnothing(index) ? libraw_unpack_thumb(p.handle) :
            libraw_unpack_thumb_ex(p.handle, index-1)
        _check(p, :unpack_thumbnail, code)
        p.thumbnail_ready = true
    end
    p
end
"""
    thumbnail(p::LibRawProcessor) -> AbstractThumbnail

Copy the currently unpacked preview as [`JPEGThumbnail`](@ref) or
[`BitmapThumbnail`](@ref). Requires a successful [`unpack_thumbnail!`](@ref)
for the current input; this call does not unpack anything itself. The result is
independent of the processor's lifetime. See [`extract_thumbnail!`](@ref) for
usage and missing-thumbnail handling.
"""
function thumbnail(p::LibRawProcessor)
    _require_open(p)
    p.thumbnail_ready || throw(ArgumentError("thumbnail has not been unpacked"))
    _memory_image(p, :make_mem_thumb, libraw_dcraw_make_mem_thumb; thumbnail = true)
end
"""
    extract_thumbnail!(p::LibRawProcessor; index=nothing)

Unpack and copy an embedded preview without decoding the full sensor image.
Return [`JPEGThumbnail`](@ref), [`BitmapThumbnail`](@ref), or `nothing` only
when LibRaw reports that no thumbnail exists. Corrupt input, unsupported formats,
and invalid indices still throw. An explicit `index` is one-based.

```julia
openraw("photo.nef"; unpack=false) do p
    thumb = extract_thumbnail!(p)
    if thumb isa JPEGThumbnail
        write("preview.jpg", thumb.data)
    elseif thumb isa BitmapThumbnail
        pixels = thumb.data # height × width × channels; encode with an image writer
        println(size(pixels))
    end
end
```

JPEG dimensions reported by LibRaw may be zero; decode the JPEG bytes when
reliable dimensions are needed. See
[`libraw_processed_image_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_processed_image_t).
"""
function extract_thumbnail!(p::LibRawProcessor; index::Union{Nothing,Integer} = nothing)
    try
        unpack_thumbnail!(p, index)
        thumbnail(p)
    catch e
        e isa LibRawError && e.code == Int(LibRawRaw.LIBRAW_NO_THUMBNAIL) && return nothing
        rethrow()
    end
end
