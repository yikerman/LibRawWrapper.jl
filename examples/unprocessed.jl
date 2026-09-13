# LibRaw unprocessed_raw equivalent: copy sensor samples and inspect the CFA.
using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
openraw(path) do p
    sensor = sensor_image(p; visible = true)
    println("visible sensor: ", size(sensor.data), " ", eltype(sensor.data))
    println("layout: ", sensor.layout)
    if sensor.layout isa CFALayout
        println("CFA pattern:\n", cfa_pattern(sensor))
        println("top-left channel: ", color_index(sensor, 1, 1))
    end
end
