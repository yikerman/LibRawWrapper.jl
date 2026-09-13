using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
p = LibRawProcessor()
try
    open!(p, path)
    unpack!(p)
    process!(p)
    image = processed_image(p)
    println(
        "processed $(image.width) × $(image.height), $(image.colors) channels, $(image.bits)-bit",
    )
    open("processed.raw", "w") do io
        write(io, image.data)
    end
finally
    close!(p)
end
