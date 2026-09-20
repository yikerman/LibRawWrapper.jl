# API Reference

This page is generated from the high-level Julia docstrings. Start with
[`openraw`](@ref), choose rendering options with [`ProcessingParams`](@ref),
and use [`postprocess!`](@ref), [`sensor_image`](@ref), or [`snapshot`](@ref)
according to the result you need. All returned image and metadata values own
their copied data.

The generated C ABI follows the upstream [C API](https://www.libraw.org/docs/API-C.html),
[C++ operation descriptions](https://www.libraw.org/docs/API-CXX.html), and
[native structures](https://www.libraw.org/docs/API-datastruct-eng.html).

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
