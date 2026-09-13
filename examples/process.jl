using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
output = get(ARGS, 2, "processed.ppm")

# dcraw_make_mem_image returns a bitmap; postprocess! copies it into a
# Julia-owned ProcessedImage before the PPM writer interleaves RGB channels.
openraw(path) do p
    image = postprocess!(p; output_type = UInt8, color_space = SRGB)
    h, w, channels = size(image.data)
    channels == 3 || error("PPM output requires a 3-channel bitmap")
    open(output, "w") do io
        write(io, "P6\n$(w) $(h)\n255\n")
        for row = 1:h, col = 1:w
            write(io, image.data[row, col, 1])
            write(io, image.data[row, col, 2])
            write(io, image.data[row, col, 3])
        end
    end
end
println("wrote PPM: ", output)
