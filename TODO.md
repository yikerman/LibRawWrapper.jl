# Follow-up work

`LibRawRaw` remains the complete generated C ABI. The high-level API covers the
normal open → unpack → inspect → process workflow and returns Julia-owned
snapshots and image data.

## Completed

- Validated `ProcessingParams` for white balance, demosaic, color space, gamma,
  brightness, highlights, orientation, and output depth.
- Lifecycle-safe `LibRawProcessor` with path, byte-vector, and IO inputs.
- Fatal-error handling, recycling, finalization, and one-based thumbnail access.
- Typed processed images and JPEG/bitmap thumbnails.
- CFA-aware Bayer/X-Trans access, visible crops, channel indices, and floating-
  point or multichannel sensor buffers.
- Snapshots for core image, color, lens, shooting, thumbnail, and raw-data
  metadata, with owned vendor/common/lens dictionaries, DNG color and level
  records, and retained autofocus, Nikon burst, and DNG opcode payloads.

## Remaining

- Expose `libraw_open_file_ex` options and a safe `open_bayer!` convenience API.
- Add typed accessors for remaining output controls such as FBDD noise
  reduction, maximum adjustment threshold, output TIFF mode, and crop boxes.
- Add copied ICC, XMP, and GPS metadata.
- Add rooted callback helpers, progress cancellation, and callback cleanup.
- Add managed wrappers for `dcraw_ppm_tiff_writer`, `dcraw_thumb_writer`,
  `recycle_datastream`, `subtract_black`, `free_image`, and
  `adjust_sizes_info_only` where useful.

## Raw-only by design

Callback records, custom datastream classes, and internal decoder structures
remain available through `LibRawRaw`. Vendor metadata is exposed as owned
dictionaries whose keys follow the pinned native version, rather than stable
typed records.

## Alternative binding distribution

- [ ] Evaluate storing the generated per-platform Julia bindings as platform-specific Pkg artifacts selected through `Artifacts.toml`, instead of committing one generated source file per target. This could reduce runtime dispatch code, but would require publishing and hashing generated-source artifacts and would make binding review less direct.
