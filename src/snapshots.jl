"""
Copy a NUL-terminated native character tuple as bytes, preserving non-ASCII values without signed integer conversion.
"""
function _chars(x)
    v = reinterpret(UInt8, collect(x))
    z = findfirst(iszero, v)
    String(v[1:(isnothing(z) ? length(v) : z-1)])
end
"""
Copy a nested row-major native tuple into a Julia matrix with the same logical rows and columns.
"""
_mat(x::NTuple{R,NTuple{C,T}}) where {R,C,T} = [x[r][c] for r = 1:R, c = 1:C]

"""
Copy bounded metadata aggregates recursively, replacing pointers, oversized arrays, and deeply nested values with `nothing`.
"""
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

"""
Convert native geometry fields into Julia integer dimensions without retaining native storage.
"""
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

"""
Copy current, stage-dependent [`ImageSizes`](@ref) from an opened input; sensor snapshots retain the original unpacked geometry.
"""
function image_sizes(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _sizes(_load(p.handle, Val(:sizes)))
end
"""
Copy camera/file identification strings and channel descriptors into [`ImageIdentity`](@ref); requires an opened input.
"""
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

"""
Copy calibration fields individually to avoid loading the large tone-curve tuple, validating spatial black-level dimensions first.
"""
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
"""
Copy current calibration into [`ColorData`](@ref); processing may change it, while `snapshot(p).sensor_color` retains unpack-time values.
"""
function color_data(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _color_data(_fieldptr(p.handle, Val(:color)))
end

"""
    tone_curve(p::LibRawProcessor) -> Vector{UInt16}

Copy the 65,536-entry sensor tone-curve table saved in native raw data. Requires
unpacking; neither runs processing nor returns the configured output gamma curve.
Julia entry `i + 1` corresponds to native curve index `i`. Use this alongside
[`sensor_image`](@ref) when inspecting decoder calibration; the vector remains
valid after the processor closes.

See [`libraw_colordata_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_colordata_t).
"""
function tone_curve(p::LibRawProcessor)
    _require_unpacked(p)
    GC.@preserve p begin
        c = _fieldptr(_fieldptr(p.handle, Val(:rawdata)), Val(:color))
        ptr = Ptr{UInt16}(_fieldptr(c, Val(:curve)))
        copy(unsafe_wrap(Vector{UInt16}, ptr, 65536; own = false))
    end
end
"""
Copy exposure, timestamp, description, and artist fields into [`ImageOther`](@ref); requires an opened input.
"""
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
"""
Copy lens identification and focal/aperture limits into [`LensInfo`](@ref); requires an opened input.
"""
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
"""
Copy camera shooting modes and serial numbers into [`ShootingInfo`](@ref); requires an opened input.
"""
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
"""
Copy [`ThumbnailInfo`](@ref) from an opened input; `data` is empty until a thumbnail has been unpacked.
"""
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
"""
Return [`RawDataInfo`](@ref) using cached unpack-time geometry when available, otherwise current geometry; requires an opened input.
"""
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

"""
    snapshot(p::LibRawProcessor) -> RawSnapshot

Copy the current supported metadata into a value that can outlive the processor.
Requires an opened input, but does not unpack or render. `state` records the
observed lifecycle stage; `color` reflects current calibration and `sensor_color`
contains the separately copied unpack-time calibration, or `nothing` before
unpacking. Thumbnail bytes are included only after thumbnail unpacking.

Arrays and dictionaries are independent copies, not deeply immutable values.
`maker_notes` currently contains vendor keys with `nothing` placeholders;
detailed vendor values remain available through the raw API. `dng[:entries]`
contains copied native DNG color entries, not every DNG tag.

```julia
info = openraw("photo.nef") do p
    snapshot(p)
end
println(info.identity.model)  # safe after the native processor has closed
```

Use individual accessors for smaller queries. The native aggregates are described
in [LibRaw data structures](https://www.libraw.org/docs/API-datastruct-eng.html).
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
