# Extract an embedded thumbnail, analogous to LibRaw thumbnail samples.
using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
openraw(path; unpack = false) do p
    thumb = extract_thumbnail!(p)
    thumb === nothing && error("file has no readable thumbnail")
    width, height =
        thumb isa JPEGThumbnail ? (thumb.width, thumb.height) :
        (size(thumb.data, 2), size(thumb.data, 1))
    println("thumbnail: ", width, " × ", height)
    write(get(ARGS, 2, "thumbnail.bin"), thumb.data)
end
