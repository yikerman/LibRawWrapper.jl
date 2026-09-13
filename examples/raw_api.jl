using LibRawWrapper

path = length(ARGS) == 1 ? ARGS[1] : joinpath(@__DIR__, "..", "test", "data", "test.nef")
handle = libraw_init(0)
handle == C_NULL && error("libraw_init failed")
try
    code = libraw_open_file(handle, path)
    code == 0 || error(:open_file, ": ", unsafe_string(libraw_strerror(code)))
    code = libraw_unpack(handle)
    code == 0 || error(:unpack, ": ", unsafe_string(libraw_strerror(code)))
    println(
        "raw size: ",
        libraw_get_raw_width(handle),
        " × ",
        libraw_get_raw_height(handle),
    )
    println("camera RGB matrix:\n", [libraw_get_rgb_cam(handle, i, j) for i = 0:2, j = 0:3])
finally
    libraw_close(handle)
end
