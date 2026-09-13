# LibRaw raw-identify equivalent: print stable file and camera metadata.
using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
openraw(path) do p
    s = snapshot(p)
    println("make: ", s.identity.make)
    println("model: ", s.identity.model)
    println("software: ", s.identity.software)
    println("raw dimensions: ", s.sizes.raw_width, " × ", s.sizes.raw_height)
    println("visible dimensions: ", s.sizes.width, " × ", s.sizes.height)
    println(
        "ISO: ",
        s.other.iso_speed,
        "  shutter: ",
        s.other.shutter,
        "  aperture: ",
        s.other.aperture,
    )
end
