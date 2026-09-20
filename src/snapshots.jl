function _chars(x)
    v = reinterpret(UInt8, collect(x))
    z = findfirst(iszero, v)
    String(v[1:(isnothing(z) ? length(v) : z-1)])
end
_mat(x::NTuple{R,NTuple{C,T}}) where {R,C,T} = [x[r][c] for r = 1:R, c = 1:C]

function _dictvalue(x, depth = 0)
    x isa Ptr && return nothing
    x isa Union{Number,Enum,CEnum.Cenum,Symbol,AbstractString} && return x
    depth > 2 && return nothing
    x isa NamedTuple &&
        return Dict{Symbol,Any}(k => _dictvalue(v, depth+1) for (k, v) in pairs(x))
    x isa Union{Tuple,AbstractArray} &&
        return length(x) > 256 ? nothing : [_dictvalue(v, depth+1) for v in x]
    isstructtype(typeof(x)) || return nothing
    Dict{Symbol,Any}(
        n => _dictvalue(getfield(x, n), depth+1) for n in fieldnames(typeof(x))
    )
end

_sizes(s::libraw_image_sizes_t) = ImageSizes(
    Int(s.raw_width),
    Int(s.raw_height),
    Int(s.width),
    Int(s.height),
    Int(s.iwidth),
    Int(s.iheight),
    Int(s.top_margin),
    Int(s.left_margin),
    Int(s.raw_pitch),
    Float64(s.pixel_aspect),
    Int(s.flip),
)

"""Copy LibRaw image dimensions and layout fields."""
function image_sizes(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _sizes(_load(p.handle, Val(:sizes)))
end
"""Copy camera and file identity metadata."""
function image_identity(p::LibRawProcessor)
    _require_open(p)
    s = GC.@preserve p _load(p.handle, Val(:idata))
    ImageIdentity(
        _chars(s.make),
        _chars(s.model),
        _chars(s.normalized_make),
        _chars(s.normalized_model),
        _chars(s.software),
        UInt32(s.maker_index),
        UInt32(s.raw_count),
        Int(s.colors),
        UInt32(s.filters),
    )
end

function _color_data(c::Ptr{libraw_colordata_t})
    blackptr = Ptr{UInt32}(_fieldptr(c, Val(:cblack)))
    channel_black = ntuple(i -> unsafe_load(blackptr, i), 4)
    rows, cols = Int(unsafe_load(blackptr, 5)), Int(unsafe_load(blackptr, 6))
    capacity = fieldcount(fieldtype(libraw_colordata_t, :cblack)) - 6
    n = Base.checked_mul(rows, cols)
    n <= capacity || throw(ArgumentError("invalid spatial black-level dimensions"))
    spatial = [unsafe_load(blackptr, 6+(r-1)*cols+k) for r = 1:rows, k = 1:cols]
    ColorData(
        _load(c, Val(:cam_mul)),
        _load(c, Val(:pre_mul)),
        _mat(_load(c, Val(:rgb_cam))),
        _mat(_load(c, Val(:cam_xyz))),
        _mat(_load(c, Val(:cmatrix))),
        _mat(_load(c, Val(:ccm))),
        _load(c, Val(:black)),
        _load(c, Val(:data_maximum)),
        _load(c, Val(:maximum)),
        _load(c, Val(:linear_max)),
        channel_black,
        spatial,
        _load(c, Val(:fmaximum)),
        _load(c, Val(:fnorm)),
    )
end
"""Copy color calibration and black-level metadata."""
function color_data(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _color_data(_fieldptr(p.handle, Val(:color)))
end

"""Copy the unpacked sensor tone curve. Requires unpacking; does not process pixels."""
function tone_curve(p::LibRawProcessor)
    _require_unpacked(p)
    GC.@preserve p begin
        c = _fieldptr(_fieldptr(p.handle, Val(:rawdata)), Val(:color))
        ptr = Ptr{UInt16}(_fieldptr(c, Val(:curve)))
        copy(unsafe_wrap(Vector{UInt16}, ptr, 65536; own = false))
    end
end
"""Copy exposure and descriptive image metadata."""
function image_other(p::LibRawProcessor)
    _require_open(p)
    s = GC.@preserve p _load(p.handle, Val(:other))
    ImageOther(
        s.iso_speed,
        s.shutter,
        s.aperture,
        s.focal_len,
        Int64(s.timestamp),
        UInt32(s.shot_order),
        _chars(s.desc),
        _chars(s.artist),
    )
end
"""Copy lens identification metadata."""
function lens_info(p::LibRawProcessor)
    _require_open(p)
    s = GC.@preserve p _load(p.handle, Val(:lens))
    LensInfo(
        _chars(s.LensMake),
        _chars(s.Lens),
        _chars(s.LensSerial),
        s.MinFocal,
        s.MaxFocal,
        s.MaxAp4MinFocal,
        s.MaxAp4MaxFocal,
        Int(s.FocalLengthIn35mmFormat),
    )
end
"""Copy camera shooting-mode metadata."""
function shooting_info(p::LibRawProcessor)
    _require_open(p)
    s = GC.@preserve p _load(p.handle, Val(:shootinginfo))
    ShootingInfo(
        Int(s.DriveMode),
        Int(s.FocusMode),
        Int(s.MeteringMode),
        Int(s.AFPoint),
        Int(s.ExposureMode),
        Int(s.ExposureProgram),
        Int(s.ImageStabilization),
        _chars(s.BodySerial),
        _chars(s.InternalBodySerial),
    )
end
"""Copy embedded thumbnail metadata and bytes when available."""
function thumbnail_info(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p begin
        s = _load(p.handle, Val(:thumbnail))
        bytes =
            !p.thumbnail_ready || s.thumb == C_NULL ? UInt8[] :
            copy(
                unsafe_wrap(
                    Vector{UInt8},
                    Ptr{UInt8}(s.thumb),
                    Int(s.tlength);
                    own = false,
                ),
            )
        ThumbnailInfo(s.tformat, Int(s.twidth), Int(s.theight), Int(s.tcolors), bytes)
    end
end
"""Copy raw sensor dimensions and storage information."""
function raw_data_info(p::LibRawProcessor)
    _require_open(p)
    s = isnothing(p.sensor_geometry) ? image_sizes(p) : p.sensor_geometry
    RawDataInfo(
        s.raw_width,
        s.raw_height,
        s.width,
        s.height,
        image_identity(p).colors,
        s.raw_pitch,
        s.pixel_aspect,
        s.flip,
    )
end

"""Copy current metadata and original sensor calibration without unpacking or processing.
Arrays and dictionaries are independent copies, not deeply immutable objects.
"""
function snapshot(p::LibRawProcessor)
    _require_open(p)
    # Detailed vendor fields remain raw-only; avoid traversing huge ABI tuples.
    maker = Dict{Symbol,Any}(n => nothing for n in fieldnames(libraw_makernotes_t))
    dng = GC.@preserve p begin
        entries = _load(_fieldptr(p.handle, Val(:color)), Val(:dng_color))
        Dict{Symbol,Any}(:entries => [_dictvalue(v) for v in entries])
    end
    RawSnapshot(
        p.state,
        image_sizes(p),
        image_identity(p),
        color_data(p),
        deepcopy(p.sensor_color),
        image_other(p),
        lens_info(p),
        shooting_info(p),
        raw_data_info(p),
        thumbnail_info(p),
        maker,
        dng,
    )
end
