"""Lifecycle state of a [`LibRawProcessor`](@ref)."""
@enum ProcessorState Empty Opened Unpacked Working Processed Failed Closed
@enum CFAKind Bayer XTrans PeriodicCFA
@enum ColorSpace CameraColor=0 SRGB=1 AdobeRGB=2 WideGamutRGB=3 ProPhotoRGB=4 XYZ=5 ACES=6
@enum DemosaicAlgorithm DefaultDemosaic=-1 LinearDemosaic=0 VNG=1 PPG=2 AHD=3 DCB=4 DHT=11 AAHD=12
@enum Orientation CameraOrientation=-1 Unrotated=0 Rotate180=3 Rotate90CCW=5 Rotate90CW=6
@enum HighlightMode ClipHighlights=0 PreserveHighlights=1 BlendHighlights=2 ReconstructHighlights=3

"""White-balance strategy used by [`ProcessingParams`](@ref)."""
abstract type WhiteBalance end
struct DaylightWB <: WhiteBalance end
struct CameraWB <: WhiteBalance end
struct AutoWB <: WhiteBalance end
struct CustomWB <: WhiteBalance
    coefficients::NTuple{4,Float32}
    function CustomWB(coefficients)
        length(coefficients) == 4 ||
            throw(ArgumentError("white balance requires four channel coefficients"))
        values = Tuple(Float32.(coefficients))
        all(x -> isfinite(x) && x > 0, values) ||
            throw(ArgumentError("white balance coefficients must be finite and positive"))
        new(values)
    end
end

"""Validated LibRaw rendering options. `output_type` is `UInt8` or `UInt16`.
`gamma` uses LibRaw's (exponent, slope) convention; `(1, 1)` is linear.
`nothing` selects the installed library's default gamma.
"""
struct ProcessingParams{T,W<:WhiteBalance}
    white_balance::W
    color_space::ColorSpace
    demosaic::DemosaicAlgorithm
    half_size::Bool
    orientation::Orientation
    gamma::Union{Nothing,NTuple{2,Float64}}
    brightness::Float32
    auto_bright::Bool
    highlights::HighlightMode
    function ProcessingParams(;
        output_type::Type = UInt8,
        white_balance::WhiteBalance = DaylightWB(),
        color_space::ColorSpace = SRGB,
        demosaic::DemosaicAlgorithm = DefaultDemosaic,
        half_size::Bool = false,
        orientation::Orientation = CameraOrientation,
        gamma = nothing,
        brightness::Real = 1,
        auto_bright::Bool = true,
        highlights::HighlightMode = ClipHighlights,
    )
        output_type in (UInt8, UInt16) ||
            throw(ArgumentError("output_type must be UInt8 or UInt16"))
        white_balance isa Union{DaylightWB,CameraWB,AutoWB,CustomWB} ||
            throw(ArgumentError("unsupported white balance strategy"))
        b = Float32(brightness)
        isfinite(b) && b > 0 ||
            throw(ArgumentError("brightness must be finite and positive"))
        g = if isnothing(gamma)
            nothing
        else
            length(gamma) == 2 || throw(ArgumentError("gamma requires exponent and slope"))
            v = Tuple(Float64.(gamma))
            isfinite(v[1]) && v[1] > 0 && isfinite(v[2]) && v[2] >= 0 ||
                throw(ArgumentError("invalid gamma exponent or slope"))
            v
        end
        new{output_type,typeof(white_balance)}(
            white_balance,
            color_space,
            demosaic,
            half_size,
            orientation,
            g,
            b,
            auto_bright,
            highlights,
        )
    end
end

"""Image dimensions, margins, pitch, and orientation reported by LibRaw.
See [`libraw_image_sizes_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_image_sizes_t).
"""
struct ImageSizes
    raw_width::Int
    raw_height::Int
    width::Int
    height::Int
    iwidth::Int
    iheight::Int
    top_margin::Int
    left_margin::Int
    raw_pitch::Int
    pixel_aspect::Float64
    flip::Int
end
"""Camera and file identity fields from [`libraw_iparams_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_iparams_t)."""
struct ImageIdentity
    make::String
    model::String
    normalized_make::String
    normalized_model::String
    software::String
    maker_index::UInt32
    raw_count::UInt32
    colors::Int
    filters::UInt32
end
"""Copied color calibration and black-level data from LibRaw.
See [`libraw_colordata_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_colordata_t).
"""
struct ColorData
    cam_mul::NTuple{4,Float32}
    pre_mul::NTuple{4,Float32}
    rgb_cam::Matrix{Float32}
    cam_xyz::Matrix{Float32}
    cmatrix::Matrix{Float32}
    ccm::Matrix{Float32}
    black::UInt32
    data_maximum::UInt32
    maximum::UInt32
    linear_max::NTuple{4,UInt32}
    channel_black::NTuple{4,UInt32}
    spatial_black::Matrix{UInt32}
    floating_maximum::Float32
    floating_normalization::Float32
end
"""Exposure, capture-time, and descriptive fields from [`libraw_imgother_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_imgother_t)."""
struct ImageOther
    iso_speed::Float32
    shutter::Float32
    aperture::Float32
    focal_length::Float32
    timestamp::Int64
    shot_order::UInt32
    description::String
    artist::String
end
"""Lens identification and focal/aperture limits from [`libraw_lensinfo_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_lensinfo_t)."""
struct LensInfo
    make::String
    name::String
    serial::String
    min_focal::Float32
    max_focal::Float32
    max_aperture_min_focal::Float32
    max_aperture_max_focal::Float32
    focal_35mm::Int
end
"""Camera shooting-mode and autofocus fields."""
struct ShootingInfo
    drive_mode::Int
    focus_mode::Int
    metering_mode::Int
    af_point::Int
    exposure_mode::Int
    exposure_program::Int
    image_stabilization::Int
    body_serial::String
    internal_body_serial::String
end
"""Embedded thumbnail metadata and copied payload bytes from [`libraw_thumbnail_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_thumbnail_t)."""
struct ThumbnailInfo
    format::LibRawRaw.LibRaw_thumbnail_formats
    width::Int
    height::Int
    colors::Int
    data::Vector{UInt8}
end
"""Dimensions and layout of raw sensor data from [`libraw_rawdata_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_rawdata_t)."""
struct RawDataInfo
    raw_width::Int
    raw_height::Int
    width::Int
    height::Int
    colors::Int
    raw_pitch::Int
    pixel_aspect::Float64
    flip::Int
end
"""Immutable, Julia-owned snapshot of supported LibRaw metadata.
Fields correspond to aggregates described in the [LibRaw C API](https://www.libraw.org/docs/API-C.html#libraw_data_t).
"""
struct RawSnapshot
    state::ProcessorState
    sizes::ImageSizes
    identity::ImageIdentity
    color::ColorData
    sensor_color::Union{Nothing,ColorData}
    other::ImageOther
    lens::LensInfo
    shooting::ShootingInfo
    raw::RawDataInfo
    thumbnail::ThumbnailInfo
    maker_notes::Dict{Symbol,Any}
    dng::Dict{Symbol,Any}
end

"""Description of the channel layout in a [`SensorImage`](@ref)."""
abstract type SensorLayout end
"""Periodic color-filter-array pattern, such as Bayer or X-Trans."""
struct CFALayout <: SensorLayout
    kind::CFAKind
    pattern::Matrix{UInt8}
    channel_labels::String
end
"""Single-channel sensor layout."""
struct MonochromeLayout <: SensorLayout end
"""Non-CFA sensor layout with named channels."""
struct MultichannelLayout <: SensorLayout
    channel_labels::String
end

"""Owned sensor samples in row/column[/channel] order, with a one-based sensor origin.
No black subtraction, rotation, interpolation, or write-back is performed.
"""
struct SensorImage{T,N,L<:SensorLayout}
    data::Array{T,N}
    layout::L
    geometry::ImageSizes
    origin::Tuple{Int,Int}
end
"""Settings associated with a processed output image."""
struct OutputMetadata
    color_space::ColorSpace
    gamma::NTuple{2,Float64}
    orientation::Orientation
    half_size::Bool
end
"""Owned numeric image in (height, width, channels) order, with output settings."""
struct ProcessedImage{T}
    data::Array{T,3}
    metadata::OutputMetadata
end
"""Common supertype for owned decoded thumbnail representations."""
abstract type AbstractThumbnail end
"""JPEG thumbnail bytes with their encoded dimensions."""
struct JPEGThumbnail <: AbstractThumbnail
    data::Vector{UInt8}
    width::Int
    height::Int
end
"""Decoded bitmap thumbnail in height × width × channel order."""
struct BitmapThumbnail{T} <: AbstractThumbnail
    data::Array{T,3}
end
"""Known warning flags and unknown bits returned by LibRaw processing."""
struct ProcessingWarnings
    known::Vector{LibRawRaw.LibRaw_warnings}
    unknown_bits::UInt32
end
