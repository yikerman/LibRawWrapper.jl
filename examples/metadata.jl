using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
p = LibRawProcessor()
try
    open!(p, path)
    unpack!(p)
    s = snapshot(p)
    println("camera: $(s.identity.make) $(s.identity.model)")
    println("lens: $(s.lens.make) $(s.lens.name)")
    println(
        "exposure: ISO $(s.other.iso_speed), $(s.other.shutter)s, f/$(s.other.aperture)",
    )
    println("dimensions: $(s.sizes.width) × $(s.sizes.height)")
finally
    close!(p)
end
