# Extract an embedded thumbnail, analogous to LibRaw thumbnail samples.
using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
openraw(path; unpack = false) do p
    thumb = extract_thumbnail!(p)
    thumb === nothing && error("file has no readable thumbnail")
    println("thumbnail: ", thumb.width, " × ", thumb.height)
    write(get(ARGS, 2, "thumbnail.bin"), thumb.data)
end
