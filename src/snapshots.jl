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
Copy a native metadata aggregate field by field, avoiding large ABI tuple loads.
The caller must preserve the processor while reading. Pointer fields require an
explicit length-aware method in `_metadata_field`.
"""
function _metadata_value(ptr::Ptr{T}) where {T}
    Dict{Symbol,Any}(n => _metadata_field(ptr, Val(n)) for n in fieldnames(T))
end

"""Read a scalar metadata value without changing native codes or sentinel values."""
_metadata_value(ptr::Ptr{T}) where {T<:Union{Number,CEnum.Cenum}} = unsafe_load(ptr)

"""Reject unhandled native pointers rather than returning borrowed storage or silently dropping data."""
_metadata_value(::Ptr{Ptr{T}}) where {T} =
    throw(ArgumentError("metadata pointer requires an explicit copy rule"))

"""
Copy inline arrays as vectors, with nested vectors preserving native row order.
Read elements through pointers so even large DNG arrays need no tuple materialization.
"""
function _metadata_value(ptr::Ptr{NTuple{N,T}}) where {N,T}
    if T <: Union{Number,CEnum.Cenum}
        return copy(unsafe_wrap(Vector{T}, Ptr{T}(ptr), N; own = false))
    end
    [_metadata_value(Ptr{T}(Ptr{UInt8}(ptr) + (i-1)*sizeof(T))) for i = 1:N]
end

"""Copy a bounded native text field, preserving bytes and stopping at the first NUL."""
function _metadata_value(ptr::Ptr{NTuple{N,Cchar}}) where {N}
    bytes = unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(ptr), N; own = false)
    z = findfirst(iszero, bytes)
    String(bytes[1:(isnothing(z) ? N : z-1)])
end

"""Copy one inline metadata field using its generated ABI offset."""
_metadata_field(ptr, field) = _metadata_value(_fieldptr(ptr, field))

"""
Copy a native binary payload using its byte length. A null pointer means no
retained payload (`nothing`), even if LibRaw recorded a nonzero tag length.
The caller must preserve the owner; allocation bounds come from LibRaw.
"""
function _metadata_bytes(ptr::Ptr, len::Integer)
    0 <= len <= typemax(Int) || throw(ArgumentError("invalid metadata byte length"))
    ptr == C_NULL && return nothing
    copy(unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(ptr), Int(len); own = false))
end

"""Copy a retained Nikon burst table using its native byte count."""
_metadata_field(ptr::Ptr{libraw_nikon_makernotes_t}, ::Val{:BurstTable_0x0056}) =
    _metadata_bytes(
        _load(ptr, Val(:BurstTable_0x0056)),
        _load(ptr, Val(:BurstTable_0x0056_len)),
    )

"""Copy an opaque autofocus record using its native byte count."""
_metadata_field(ptr::Ptr{libraw_afinfo_item_t}, ::Val{:AFInfoData}) =
    _metadata_bytes(_load(ptr, Val(:AFInfoData)), _load(ptr, Val(:AFInfoData_length)))

"""Copy an opaque DNG opcode list using its native byte count."""
_metadata_field(ptr::Ptr{libraw_dng_rawopcode_t}, ::Val{:data}) =
    _metadata_bytes(_load(ptr, Val(:data)), _load(ptr, Val(:len)))

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
Copy current [`ImageSizes`](@ref) from an opened input. Dimensions can change with processing; sensor snapshots retain the original unpacked geometry.
"""
function image_sizes(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _sizes(_load(p.handle, Val(:sizes)))
end
"""
Copy camera and file identification strings and channel descriptors into [`ImageIdentity`](@ref). Requires an opened input.
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
Copy current calibration into [`ColorData`](@ref). Processing may change these fields; `snapshot(p).sensor_color` retains the values copied during unpacking.
"""
function color_data(p::LibRawProcessor)
    _require_open(p)
    GC.@preserve p _color_data(_fieldptr(p.handle, Val(:color)))
end

"""
    tone_curve(p::LibRawProcessor) -> Vector{UInt16}

Copy the 65,536-entry sensor tone-curve table saved in native raw data. Requires
unpacking. This does not run processing or return the configured output gamma curve.
Julia entry `i + 1` corresponds to native curve index `i`. Use this alongside
[`sensor_image`](@ref) when inspecting decoder calibration. The vector remains
valid after the processor closes. Some decoders apply this table during
unpacking, so it is not an instruction to apply it again to sensor samples.

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
Copy exposure, timestamp, description, and artist fields into [`ImageOther`](@ref). Requires an opened input.
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
Copy lens identification and focal/aperture limits into [`LensInfo`](@ref). Requires an opened input.
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
Copy camera shooting modes and serial numbers into [`ShootingInfo`](@ref). Requires an opened input.
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
Copy [`ThumbnailInfo`](@ref) from an opened input. The `data` field is empty until a thumbnail has been unpacked.
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
Return [`RawDataInfo`](@ref) using geometry saved during unpacking, or current geometry if not yet unpacked. Requires an opened input.
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
observed lifecycle stage. `color` reflects current calibration and `sensor_color`
contains the separately copied unpack-time calibration, or `nothing` before
unpacking. Thumbnail bytes are included only after thumbnail unpacking.

Arrays and dictionaries are independent, mutable copies. Dictionary keys retain
native field names and casing:

- `maker_notes[:nikon]`, `[:canon]`, etc. copy each native vendor record.
  `[:common]` contains shared fields, including firmware and autofocus records.
  `[:lens]` copies the complete native lens record, including its vendor fields.
- `dng[:version]` is the native packed DNG version (zero for non-DNG input).
  `[:entries]` contains the two DNG color records. `[:levels]` contains DNG
  levels, crops, white balance, exposure, and opcode records.

Native structs become dictionaries, text becomes strings, and arrays become
vectors (nested vectors for native matrices, indexed as `[row][column]`). Binary
payloads are copied as `Vector{UInt8}`, or `nothing` when no payload is retained.
Numeric codes, sentinels, lengths, and `parsedfields` flags remain unchanged.
All vendor records are present, including defaults for unrelated cameras.
These dictionaries expose metadata retained by LibRaw, not every tag in the file.

```julia
info = openraw("photo.nef"; unpack=false) do p
    snapshot(p)
end
println(info.identity.model)  # safe after the native processor has closed
println(info.maker_notes[:nikon][:PictureControlName])
```

Use individual accessors for smaller queries. The native aggregates are described
in [LibRaw data structures](https://www.libraw.org/docs/API-datastruct-eng.html#datastruct).
"""
function snapshot(p::LibRawProcessor)
    _require_open(p)
    maker, dng = GC.@preserve p begin
        maker = _metadata_value(_fieldptr(p.handle, Val(:makernotes)))
        maker[:lens] = _metadata_value(_fieldptr(p.handle, Val(:lens)))
        color = _fieldptr(p.handle, Val(:color))
        dng = Dict{Symbol,Any}(
            :version => _load(_fieldptr(p.handle, Val(:idata)), Val(:dng_version)),
            :entries => _metadata_value(_fieldptr(color, Val(:dng_color))),
            :levels => _metadata_value(_fieldptr(color, Val(:dng_levels))),
        )
        maker, dng
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
