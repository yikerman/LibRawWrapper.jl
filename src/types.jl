"""
Managed lifecycle stages for [`LibRawProcessor`](@ref). See [Lifecycle and ownership](@ref lifecycle).
"""
@enum ProcessorState Empty Opened Unpacked Working Processed Failed Closed
"""
Classification of a [`CFALayout`](@ref) as Bayer, X-Trans, or another repeating pattern.
"""
@enum CFAKind Bayer XTrans PeriodicCFA
"""
Output color-space selection for [`ProcessingParams`](@ref), mapped to native `output_color`.
"""
@enum ColorSpace CameraColor=0 SRGB=1 AdobeRGB=2 WideGamutRGB=3 ProPhotoRGB=4 XYZ=5 ACES=6
"""
Interpolation selection for [`ProcessingParams`](@ref), mapped to native `user_qual`. Availability depends on the sensor and library.
"""
@enum DemosaicAlgorithm DefaultDemosaic=-1 LinearDemosaic=0 VNG=1 PPG=2 AHD=3 DCB=4 DHT=11 AAHD=12
"""
Output rotation selection for [`ProcessingParams`](@ref), mapped to native `user_flip`.
"""
@enum Orientation CameraOrientation=-1 Unrotated=0 Rotate180=3 Rotate90CCW=5 Rotate90CW=6
"""
Highlight handling for [`ProcessingParams`](@ref), mapped to native `highlight`.
"""
@enum HighlightMode ClipHighlights=0 PreserveHighlights=1 BlendHighlights=2 ReconstructHighlights=3

"""
White-balance strategy for [`ProcessingParams`](@ref): `DaylightWB`, `CameraWB`, `AutoWB`, or `CustomWB`.
"""
abstract type WhiteBalance end
"""
`DaylightWB()` selects native daylight balance by leaving camera/automatic flags and custom multipliers at their defaults.
"""
struct DaylightWB <: WhiteBalance end
"""
`CameraWB()` requests camera-recorded white balance through native `use_camera_wb`. With the default LibRaw 0.22.2 settings, missing camera coefficients trigger automatic white balance. See [`libraw_output_params_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_output_params_t).
"""
struct CameraWB <: WhiteBalance end
"""
`AutoWB()` requests native automatic white balance through `use_auto_wb`.
"""
struct AutoWB <: WhiteBalance end
"""
    CustomWB(coefficients)

Supply four positive, finite channel multipliers, stored as `Float32` in
`coefficients`. For a conventional RGBG sensor, these follow red, green, blue,
second green order. Inspect the sensor's channel labels when working with other
layouts. Pass the result as `white_balance` to [`ProcessingParams`](@ref).

```jldoctest
julia> CustomWB((2, 1, 1.5, 1)).coefficients
(2.0f0, 1.0f0, 1.5f0, 1.0f0)
```

See native `user_mul` in
[`libraw_output_params_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_output_params_t).
"""
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

"""
    ProcessingParams(; output_type=UInt8, white_balance=DaylightWB(),
        color_space=SRGB, demosaic=DefaultDemosaic, half_size=false,
        orientation=CameraOrientation, gamma=nothing, brightness=1,
        auto_bright=true, highlights=ClipHighlights)

Validated rendering options for [`process!`](@ref) and [`postprocess!`](@ref).
Reuse a configuration across files or renders. Each render replaces all managed
output options, so settings from earlier renders do not carry over.

| Keyword | Meaning and accepted values |
|:--|:--|
| `output_type` | `UInt8` or `UInt16`; determines the output array element type. |
| `white_balance` | `DaylightWB()`, `CameraWB()`, `AutoWB()`, or `CustomWB(...)`. |
| `color_space` | A [`ColorSpace`](@ref), defaulting to `SRGB`. |
| `demosaic` | A [`DemosaicAlgorithm`](@ref); `DefaultDemosaic` leaves selection to LibRaw. |
| `half_size` | Request half-resolution CFA output; ignored for full-color and monochrome images. Default `false`. |
| `orientation` | An [`Orientation`](@ref); `CameraOrientation` follows file metadata. |
| `gamma` | `nothing` for the native default, or `(exponent, slope)`; exponent must be positive and slope nonnegative, both finite. `(1, 1)` selects linear gamma. |
| `brightness` | Positive finite multiplier, converted to `Float32`; default `1`. |
| `auto_bright` | Enable native automatic brightness, default `true`. |
| `highlights` | A [`HighlightMode`](@ref), defaulting to `ClipHighlights`. |

Invalid numerical options throw `ArgumentError`. Native format restrictions may
still cause a processing error or warning. Inspect [`warnings`](@ref) afterward.
`output_type` is a type parameter rather than a stored field.

```jldoctest
julia> options = ProcessingParams(output_type=UInt16, gamma=(1, 1), auto_bright=false);

julia> (options.gamma, options.auto_bright)
((1.0, 1.0), false)
```

The gamma pair maps directly to native `gamm[0:1]`: use `(1/2.4, 12.92)` for
LibRaw's sRGB curve, or `(1, 1)` for linear output. `nothing` retains the pinned
library's `(0.45, 4.5)` BT.709 settings. Selecting `SRGB` changes color coordinates
without changing gamma. `output_type=UInt16` changes bit depth only.

`auto_bright=false` disables histogram-based brightening, but leaves native
maximum adjustment and color scaling enabled. See
[`libraw_output_params_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_output_params_t)
for underlying options.
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

"""
Copied pixel dimensions, margins, byte pitch, aspect ratio, and rotation. See [`libraw_image_sizes_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_image_sizes_t).
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
"""
Copied camera identity, RAW count, channel count, and filter code. See [`libraw_iparams_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_iparams_t).
"""
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
"""
Owned calibration matrices, multipliers, and black/white levels. `channel_black` and `spatial_black` split native `cblack`. See [`libraw_colordata_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_colordata_t).
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
"""
Copied exposure and descriptive metadata, with timestamp as integer Unix seconds. See [`libraw_imgother_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_imgother_t).
"""
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
"""
Copied lens identity and focal/aperture limits. Unavailable values may be empty or zero. See [`libraw_lensinfo_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_lensinfo_t).
"""
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
"""
Copied native shooting-mode codes and camera serial strings. See `shootinginfo` in [`libraw_data_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_data_t).
"""
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
"""
Copied native thumbnail fields and payload bytes, distinct from an [`AbstractThumbnail`](@ref) result. See [`libraw_thumbnail_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_thumbnail_t).
"""
struct ThumbnailInfo
    format::LibRawRaw.LibRaw_thumbnail_formats
    width::Int
    height::Int
    colors::Int
    data::Vector{UInt8}
end
"""
Copied sensor dimensions, channel count, byte pitch, aspect ratio, and rotation. See [`libraw_rawdata_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_rawdata_t).
"""
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
"""
Owned metadata returned by [`snapshot`](@ref). Fields cannot be reassigned, but contained arrays and dictionaries remain mutable.
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

"""
Channel-layout description carried by a [`SensorImage`](@ref).
"""
abstract type SensorLayout end
"""
Periodic full-sensor CFA tile of one-based indices into `channel_labels`, classified by `kind`. Use [`cfa_pattern`](@ref) for crop alignment.
"""
struct CFALayout <: SensorLayout
    kind::CFAKind
    pattern::Matrix{UInt8}
    channel_labels::String
end
"""
Single-channel sensor without a color filter array. See [`SensorImage`](@ref).
"""
struct MonochromeLayout <: SensorLayout end
"""
Sensor with multiple samples per pixel and native `channel_labels`. See [`SensorImage`](@ref).
"""
struct MultichannelLayout <: SensorLayout
    channel_labels::String
end

"""
Owned row/column[/channel] sensor samples, layout, unpack-time geometry, and one-based full-sensor `origin`. See [`sensor_image`](@ref).
"""
struct SensorImage{T,N,L<:SensorLayout}
    data::Array{T,N}
    layout::L
    geometry::ImageSizes
    origin::Tuple{Int,Int}
end
"""
Requested output color space, gamma pair, orientation policy, and half-size setting. `CameraOrientation` records a policy, not a resolved angle.
"""
struct OutputMetadata
    color_space::ColorSpace
    gamma::NTuple{2,Float64}
    orientation::Orientation
    half_size::Bool
end
"""
Owned `(height, width, channels)` numeric `data` plus [`OutputMetadata`](@ref). See [`libraw_processed_image_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_processed_image_t).
"""
struct ProcessedImage{T}
    data::Array{T,3}
    metadata::OutputMetadata
end
"""
Owned preview result: [`JPEGThumbnail`](@ref) encoded bytes or [`BitmapThumbnail`](@ref) numeric pixels.
"""
abstract type AbstractThumbnail end
"""
Owned JPEG `data` with native `width` and `height`, which may be zero if unknown. See [`libraw_processed_image_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_processed_image_t).
"""
struct JPEGThumbnail <: AbstractThumbnail
    data::Vector{UInt8}
    width::Int
    height::Int
end
"""
Owned `(height, width, channels)` pixel `data`. Obtain dimensions with `size(data)`. See [`libraw_processed_image_t`](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_processed_image_t).
"""
struct BitmapThumbnail{T} <: AbstractThumbnail
    data::Array{T,3}
end
"""
Sorted native `known` warning flags and `unknown_bits::UInt32`, returned by [`warnings`](@ref).
"""
struct ProcessingWarnings
    known::Vector{LibRawRaw.LibRaw_warnings}
    unknown_bits::UInt32
end

# Documentation for exported enum values.
@doc "Allocated processor without an opened input. Use [`open!`](@ref)." Empty
@doc "Input metadata loaded. Sensor pixels await [`unpack!`](@ref)." Opened
@doc "Sensor data decoded and available to [`sensor_image`](@ref) or [`process!`](@ref)." Unpacked
@doc "Intermediate image prepared by [`prepare_image!`](@ref)." Working
@doc "A successful render is available through [`processed_image`](@ref)." Processed
@doc "Processor invalidated by a fatal native error or failed cache setup. Recycle or reopen before reuse." Failed
@doc "Native handle released permanently. Create a new [`LibRawProcessor`](@ref)." Closed
@doc "A 2×2 repeating CFA classification. Inspect [`CFALayout`](@ref) for channel order." Bayer
@doc "An X-Trans CFA classification. Inspect [`cfa_pattern`](@ref) for the actual tile." XTrans
@doc "A supported repeating CFA other than the Bayer or X-Trans classifications." PeriodicCFA
@doc "Leave output in native camera color coordinates ([`ColorSpace`](@ref))." CameraColor
@doc "Select sRGB output primaries. Configure gamma separately in [`ProcessingParams`](@ref)." SRGB
@doc "Select Adobe RGB output primaries ([`ColorSpace`](@ref))." AdobeRGB
@doc "Select Wide Gamut RGB output primaries ([`ColorSpace`](@ref))." WideGamutRGB
@doc "Select ProPhoto RGB output primaries ([`ColorSpace`](@ref))." ProPhotoRGB
@doc "Select CIE XYZ output coordinates ([`ColorSpace`](@ref))." XYZ
@doc "Select LibRaw ACES output color space ([`ColorSpace`](@ref))." ACES
@doc "Leave interpolation to LibRaw (the default [`DemosaicAlgorithm`](@ref))." DefaultDemosaic
@doc "Request linear interpolation ([`DemosaicAlgorithm`](@ref))." LinearDemosaic
@doc "Request variable number of gradients interpolation ([`DemosaicAlgorithm`](@ref))." VNG
@doc "Request patterned pixel grouping interpolation ([`DemosaicAlgorithm`](@ref))." PPG
@doc "Request adaptive homogeneity-directed interpolation ([`DemosaicAlgorithm`](@ref))." AHD
@doc "Request DCB interpolation ([`DemosaicAlgorithm`](@ref))." DCB
@doc "Request DHT interpolation ([`DemosaicAlgorithm`](@ref))." DHT
@doc "Request AAHD interpolation ([`DemosaicAlgorithm`](@ref))." AAHD
@doc "Follow the file orientation when rendering (the default [`Orientation`](@ref))." CameraOrientation
@doc "Request no output rotation ([`Orientation`](@ref))." Unrotated
@doc "Request 180-degree output rotation ([`Orientation`](@ref))." Rotate180
@doc "Request 90-degree counterclockwise output rotation ([`Orientation`](@ref))." Rotate90CCW
@doc "Request 90-degree clockwise output rotation ([`Orientation`](@ref))." Rotate90CW
@doc "Clip highlights using native mode 0 (the default [`HighlightMode`](@ref))." ClipHighlights
@doc "Preserve highlights using native mode 1 (unclip), a [`HighlightMode`](@ref) option." PreserveHighlights
@doc "Blend highlights using native mode 2, a [`HighlightMode`](@ref) option." BlendHighlights
@doc "Reconstruct highlights using native mode 3 (rebuild), a [`HighlightMode`](@ref) option." ReconstructHighlights
