# How the wrapper handles RAW data

## [Lifecycle and ownership](@id lifecycle)

LibRaw keeps metadata and image buffers in a mutable native processor. Calls
can replace or free that storage, invalidating pointers into it. The managed
API copies results into Julia storage so they can outlive the processor:

```julia
info = openraw("photo.nef"; unpack=false) do raw
    snapshot(raw)
end
info.identity.model  # Still available after closing.
```

Copying costs memory and time, but lets a batch job retain results while reusing
one processor. Snapshot fields cannot be reassigned, though their arrays and
dictionaries remain mutable. Creating a snapshot requires a live processor.
Use one processor per task or synchronize all access, including closing it.

The generated `LibRawRaw` module follows native ownership rules. It provides
access to callbacks and vendor metadata beyond the managed API. Raw calls
through a managed handle bypass its state tracking. The
[raw API recipe](@ref raw-api) uses a separate native handle.

### Processing stages

Opening reads metadata, unpacking decodes sensor pixels, and rendering converts
those samples into an output image. Metadata inspection and thumbnail extraction
can therefore skip sensor decoding. [`openraw`](@ref) unpacks by default.

These states are tracked by the wrapper, separately from LibRaw's progress flags:

| Operation | Required state | Resulting state on success |
|:--|:--|:--|
| [`open!`](@ref) | Any except `Closed` | `Opened` |
| [`unpack!`](@ref) | `Opened` | `Unpacked` |
| [`prepare_image!`](@ref) | `Unpacked`, `Working`, `Processed` | `Working` |
| [`process!`](@ref) / [`postprocess!`](@ref) | `Unpacked`, `Working`, `Processed` | `Processed` |
| [`unpack_thumbnail!`](@ref) | `Opened`, `Unpacked`, `Working`, `Processed` | Unchanged |
| [`recycle!`](@ref) | Any except `Closed` | `Empty` |
| [`close!`](@ref) / [`close`](@ref Base.close(::LibRawProcessor)) | Any | `Closed` |

[`working_image`](@ref) requires `Working` or `Processed`, and
[`processed_image`](@ref) requires `Processed`. [`thumbnail`](@ref) requires a
successful thumbnail unpack for the current input. Invalid call order throws
`ArgumentError`.

Each render starts from the decoded sensor data and restores output defaults
before applying its options:

```julia
openraw("photo.nef") do raw
    preview = postprocess!(raw; half_size=true, white_balance=CameraWB())
    full = postprocess!(raw)  # Full size and default daylight balance.
end
```

Recycling releases the current file's buffers but retains the handle for reuse.
Closing also releases the handle and is idempotent. [`isopen`](@ref Base.isopen(::LibRawProcessor))
reports whether the handle exists, including in `Empty` and `Failed`. A fatal
native error enters `Failed`, which requires recycling or reopening.

## [Sensor samples, working buffers, and rendered images](@id image-stages)

[`sensor_image`](@ref) copies decoded sensor values without adding black
subtraction, demosaicing, rotation, or tone mapping. The camera or decoder may
already have applied corrections, including
[black subtraction](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_colordata_t).
A CFA sensor measures one channel at each position. Monochrome and multichannel
sensors have other layouts, described by `sensor.layout`.

Cropping to the visible area removes margins and can shift the CFA phase.
`SensorImage` retains the crop's full-sensor origin so [`color_index`](@ref) and
[`cfa_pattern`](@ref) remain aligned. Their indices refer to the sensor's channel
labels, which may distinguish two greens.

[`working_image`](@ref) copies LibRaw's four-channel intermediate buffer.
Its contents depend on the processing stage. Final gamma, brightness,
orientation, and bit-depth conversion happen during
[memory export](https://www.libraw.org/docs/API-CXX.html#dcraw_make_mem_image),
which [`processed_image`](@ref) performs. [`postprocess!`](@ref) combines rendering
and export.

Rendered arrays use `(height, width, channels)` dimensions. Their column-major
storage differs from interleaved RGB file order. The
[PPM recipe](@ref write-rgb) shows how to write the samples in that order.

## Color space and tone response

Color coordinates and tone response are separate settings. Both configurations
below use sRGB primaries, with different transfer curves:

```julia
linear = ProcessingParams(color_space=SRGB, gamma=(1, 1))
display = ProcessingParams(color_space=SRGB, gamma=(1/2.4, 12.92))
```

`gamma=nothing` retains LibRaw's `(0.45, 4.5)` BT.709 settings. The first value
is the native exponent, so a conventional gamma of 2.4 is passed as `1/2.4`.
See the [output parameters](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_output_params_t).

Linear gamma still allows white balance, color conversion, brightness, and
highlight handling to change values. `auto_bright=false` disables histogram-based
brightening but leaves native maximum adjustment and color scaling enabled.
Selecting 16-bit output changes bit depth without selecting linear gamma.

## What a snapshot records

[`snapshot`](@ref) records metadata at the current processing stage. Its `color`
field reflects current calibration, while `sensor_color` preserves calibration
copied during unpacking. Before unpacking, `sensor_color` is `nothing`.
Rendering can change current metadata, including dimensions. Sensor snapshots
retain the geometry saved during unpacking.

`maker_notes` contains nested dictionaries for vendor records, shared metadata
under `:common`, and detailed lens metadata under `:lens`. Keys retain LibRaw's
field names and casing. All vendor records are included, so a key's presence
does not mean the camera supplied a value. Native defaults and sentinels remain
unchanged.

```julia
info = openraw("photo.nef"; unpack=false) do raw
    snapshot(raw)
end
info.maker_notes[:nikon][:PictureControlName]
info.maker_notes[:lens][:makernotes][:LensID]
```

`dng[:version]` is zero for non-DNG input. `dng[:entries]` holds the two native
DNG color records, and `dng[:levels]` holds levels, crops, white balance,
baseline exposure, and opcode records. Their `parsedfields` flags identify
fields LibRaw parsed. Numeric codes are not translated into labels.

Text fields become strings. Arrays become vectors, with nested vectors in
native row order for matrices (`matrix[row][column]`). Autofocus, Nikon burst,
and DNG opcode payloads are copied as byte vectors without decoding their
contents. A null native pointer becomes `nothing`, even when a tag length was
recorded. These copies survive recycling and closing the processor.

Coverage follows the metadata LibRaw retains in these records, not every tag
in the file. GPS, XMP, and ICC data still require the raw API. See
[LibRaw's metadata structures](https://www.libraw.org/docs/API-datastruct-eng.html#libraw_data_t).

## Embedded previews and failures

Embedded previews come from the file and can differ from a new LibRaw render.
The managed API supports JPEG bytes and bitmap samples. JPEG bytes can be
written directly to a `.jpg` file. Bitmaps need encoding. LibRaw may report
zero JPEG dimensions, so decode the JPEG when those dimensions matter.
Native LibRaw 0.22.2 also exports JPEG XL and H.265 previews, which the managed
API rejects with `ArgumentError`.

[`extract_thumbnail!`](@ref) returns `nothing` when no preview exists. Other
errors throw. Warnings can describe fallbacks during successful processing and
are separate from errors. See [Handle failures and inspect warnings](@ref handle-failures).
