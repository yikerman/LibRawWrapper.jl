# API reference

For processing stages and resource lifetimes, see
[Lifecycle and ownership](@ref lifecycle). For recipes, see the
[how-to guides](how-to.md).

## Data conventions

| Value | Convention |
|:--|:--|
| Sensor array | `(height, width)` for one plane, otherwise `(height, width, channels)` |
| Working array | `(height, width, 4)`, with `UInt16` samples |
| Rendered or bitmap-preview array | `(height, width, channels)` |
| CFA channel index | One-based index into `channel_labels` |
| Thumbnail selection index | One-based index into the native thumbnail list |
| Sensor origin | One-based `(row, column)` in the full sensor |
| Native row pitch | Bytes |
| JPEG preview data | Encoded bytes, with native dimensions possibly zero |

## Managed API

```@autodocs
Modules = [LibRawWrapper]
Order = [:type, :function, :macro, :constant]
Public = true
Private = false
```

## Base integration

```@docs
Base.close(::LibRawProcessor)
Base.isopen(::LibRawProcessor)
```

## Native API

This manual targets the pinned LibRaw 0.22.2 release. For version-specific
details, use its [source and headers](https://github.com/LibRaw/LibRaw/tree/0.22.2)
alongside the online documentation, which contains some descriptions of older
releases.

The generated `LibRawWrapper.LibRawRaw` module follows the upstream
[C API](https://www.libraw.org/docs/API-C.html),
[C++ operation descriptions](https://www.libraw.org/docs/API-CXX.html), and
[native structures](https://www.libraw.org/docs/API-datastruct-eng.html).
Its pointers and buffers follow native lifetime rules. See
[Call the raw C API](@ref raw-api) for a complete handle lifecycle.
