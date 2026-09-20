# LibRawWrapper.jl

Read RAW photographs in [Julia](https://julialang.org/) with
[LibRaw](https://www.libraw.org/). Use the managed Julia API to inspect metadata,
read sensor samples, and render images. The generated C API is available for direct access to LibRaw.

## Quick start

```julia
using LibRawWrapper

openraw("photo.nef") do raw
    info = snapshot(raw)
    println("$(info.identity.make) $(info.identity.model)")
    sensor = sensor_image(raw)
    println(size(sensor.data), " ", sensor.layout)
    image = postprocess!(raw; output_type=UInt16)
    pixels = image.data
end
```

Metadata snapshots, sensor samples, rendered images, and thumbnails are copied
into Julia storage and remain valid after the processor is recycled or closed.
Start with the [tutorial](docs/src/tutorial.md), find a recipe in the
[how-to guides](docs/src/how-to.md), or consult the [API reference](docs/src/api.md).
The [explanation](docs/src/explanation.md) covers ownership and processing stages.

Runnable [examples](examples/) cover file identification, sensor and CFA
inspection, thumbnail extraction, memory-buffer input, and rendering.

## Two interfaces

`LibRawProcessor` is the recommended interface for application code. It
manages the LibRaw lifecycle and exposes Julia types for metadata, CFA layouts,
processing parameters, images, and thumbnails.

`LibRawRaw` is the standalone Clang.jl-generated module containing the raw C
ABI. It preserves LibRaw's structs, pointers, callbacks, and return codes.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/yikerman/LibRawWrapper.jl.git")
```

The native library and matching headers come from `LibRaw_jll`, so runtime and
binding generation use one LibRaw release artifact.

## Development

```bash
make generate   # regenerate src/bindings/*.jl from LibRaw_jll headers
make parse      # load and precompile the complete package
make format     # format Julia source files
make test       # run the test suite
make test-examples # run every example against the bundled fixture
make deps        # instantiate root and documentation/generator environments
make docs       # build Documenter.jl documentation
make check      # precompile and test
```

`make generate` writes per-platform raw modules to `src/bindings/`, selected
by `src/raw.jl`. The managed layer lives in `src/types.jl`, `src/highlevel.jl`,
`src/snapshots.jl`, `src/sensor.jl`, and `src/processing.jl`.

## License

LibRawWrapper is licensed under LGPL-3.0-or-later. See [COPYING.LESSER](COPYING.LESSER)
and the accompanying [GPL-3.0 text](COPYING). Native dependencies and the
bundled photograph retain their respective licenses and rights.
