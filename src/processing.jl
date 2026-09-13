function _setfield!(ptr, field::Val, value)
    dest = _fieldptr(ptr, field)
    unsafe_store!(dest, convert(eltype(typeof(dest)), value))
end

_apply_wb!(params, ::DaylightWB) = nothing
_apply_wb!(params, ::CameraWB) = _setfield!(params, Val(:use_camera_wb), 1)
_apply_wb!(params, ::AutoWB) = _setfield!(params, Val(:use_auto_wb), 1)
_apply_wb!(params, wb::CustomWB) = _setfield!(params, Val(:user_mul), wb.coefficients)

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

"""Render unpacked data through LibRaw with a complete validated configuration.
Repeated calls start from the original sensor data. Returns the processor.
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

function _bitmap(ptr::Ptr{UInt8}, width, height, channels, bits, nbytes)
    bits in (8, 16) || throw(ArgumentError("unsupported bitmap bit depth: $bits"))
    T = bits == 8 ? UInt8 : UInt16
    pitch = Base.checked_mul(Base.checked_mul(width, channels), sizeof(T))
    nbytes == Base.checked_mul(height, pitch) ||
        throw(ArgumentError("bitmap payload size disagrees with dimensions"))
    _copy_pixels(Ptr{T}(ptr), height, width, channels, pitch)
end

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

"""Copy the last rendered image to a typed Julia array; does not run processing."""
function processed_image(p::LibRawProcessor)
    _require(p, Processed)
    _memory_image(p, :make_mem_image, libraw_dcraw_make_mem_image)
end
"""Render and return an owned `ProcessedImage{T}`. Requires prior unpacking."""
function postprocess!(p::LibRawProcessor, params::ProcessingParams{T}; kwargs...) where {T}
    process!(p, params; kwargs...)
    processed_image(p)::ProcessedImage{T}
end
postprocess!(p::LibRawProcessor; kwargs...) = postprocess!(p, ProcessingParams(; kwargs...))

"""Unpack an embedded thumbnail; `index` is one-based when provided."""
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
"""Copy the currently unpacked thumbnail into a Julia-owned value."""
function thumbnail(p::LibRawProcessor)
    _require_open(p)
    p.thumbnail_ready || throw(ArgumentError("thumbnail has not been unpacked"))
    _memory_image(p, :make_mem_thumb, libraw_dcraw_make_mem_thumb; thumbnail = true)
end
"""Extract a JPEG or bitmap thumbnail. Return `nothing` only when no thumbnail exists.
An explicit `index` is one-based; unsupported formats and corrupt data throw.
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
