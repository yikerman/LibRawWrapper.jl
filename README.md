# LibRawWrapper.jl

Read RAW photographs in [Julia](https://julialang.org/) with
[LibRaw](https://www.libraw.org/). The package provides a convenient Julia API
for the usual workflow and keeps the complete generated C API available when
you need lower-level control.

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

The high-level layer owns copied metadata, matrices, sensor data, processed
images, and thumbnails. `snapshot` remains valid after the underlying LibRaw
processor is recycled or closed. See the [high-level guide](docs/src/index.md)
and the runnable [examples](examples/).

The examples include raw-identification, unprocessed sensor/CFA inspection,
thumbnail extraction, memory-buffer input, and simple rendering workflows.

## Two interfaces

`LibRawProcessor` is the recommended interface for application code. It
manages the LibRaw lifecycle and exposes Julia types for metadata, CFA layouts,
processing parameters, images, and thumbnails.

`LibRawRaw` is the standalone Clang.jl-generated module containing the raw C
ABI. It preserves LibRaw's structs, pointers, callbacks, and return codes for
advanced integrations. (`LibRaw` the lib name + `Raw` raw C api)

## Installation

```julia
using Pkg
Pkg.add("LibRawWrapper")
```

The native library and matching headers come from `LibRaw_jll`, so runtime and
binding generation use one LibRaw release artifact.

## Development

```bash
make generate   # regenerate src/raw.jl from LibRaw_jll headers
make parse      # load and precompile the complete package
make format     # format Julia source files
make test       # run the test suite
make test-examples # run every example against the bundled fixture
make deps        # instantiate root and documentation/generator environments
make docs       # build Documenter.jl documentation
make check      # precompile and test
```

`make generate` writes the standalone raw module to `src/raw.jl`; the managed
layer lives in `src/types.jl`, `src/highlevel.jl`, `src/snapshots.jl`,
`src/sensor.jl`, and `src/processing.jl`.
