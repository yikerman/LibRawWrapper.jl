using LibRawWrapper

path = length(ARGS) == 1 ? ARGS[1] : joinpath(@__DIR__, "..", "test", "data", "test.nef")
openraw(path) do p
    info = metadata(p)
    println("camera: ", info.make, " ", info.model)
    println("size: ", info.width, " × ", info.height)
    println("RGB camera matrix:\n", rgb_cam_matrix(p))
    raw = sensor_image(p)
    println("raw Julia array: ", size(raw.data), " ", eltype(raw.data), " ", raw.layout)
end
