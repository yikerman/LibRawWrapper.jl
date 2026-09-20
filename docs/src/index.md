# LibRawWrapper.jl

Read RAW photographs in Julia with LibRaw. Use [`LibRawProcessor`](@ref) to
inspect metadata, copy sensor pixels, render images, and extract embedded
previews. Its results remain usable after the processor closes.

The generated `LibRawWrapper.LibRawRaw` module also exposes the C API for
integrations that need native pointers, structs, or callbacks.

## Find what you need

| Goal | Start here |
|:--|:--|
| Learn the workflow with a sample photograph | [Tutorial](tutorial.md) |
| Render a file, extract a preview, or work with sensor data | [How-to guides](how-to.md) |
| Look up a function or option | [Reference](api.md) |
| Understand ownership, processing stages, and image representations | [Explanation](explanation.md) |

Runnable scripts are also available in the
[`examples/` directory](https://github.com/yikerman/LibRawWrapper.jl/tree/master/examples).
From a repository checkout, run one with:

```sh
julia --project examples/process.jl photo.nef processed.ppm
```
