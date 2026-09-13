using Test
using LibRawWrapper

@testset "LibRaw C API" begin
    version_ptr = LibRawWrapper.libraw_version()
    @test version_ptr isa Ptr{Cchar}
    @test unsafe_string(version_ptr) isa String
    @info "LibRaw version string" unsafe_string(version_ptr)
    @test LibRawWrapper.libraw_versionNumber() > 0
    @test LibRawWrapper.libraw_cameraCount() > 0

    handle = LibRawWrapper.libraw_init(0)
    @test handle isa Ptr{LibRawWrapper.libraw_data_t}
    @test handle != C_NULL
    LibRawWrapper.libraw_close(handle)
end

@testset "Julia processor API" begin
    p = LibRawProcessor()
    try
        open!(p, joinpath(@__DIR__, "data", "test.nef"))
        unpack!(p)
        @test metadata(p).model == "D850"
        @test size(rgb_cam_matrix(p)) == (3, 4)
        raw = sensor_image(p).data
        @test size(raw) == (5520, 8288)
        @test eltype(raw) == UInt16
        @test all(isfinite, rgb_cam_matrix(p))
        snap = snapshot(p)
        @test snap.identity.model == "D850"
        @test size(snap.color.rgb_cam) == (3, 4)
        @test snap.other.iso_speed > 0
        @test snap.lens.name isa String
        @test snap.maker_notes isa Dict{Symbol,Any}
        @test haskey(snap.maker_notes, :nikon)
        @test snap.dng isa Dict{Symbol,Any}
        recycle!(p)
        @test snap.identity.model == "D850"
    finally
        close!(p)
        close!(p)
    end
end

@testset "NEF fixture" begin
    path = joinpath(@__DIR__, "data", "test.nef")
    @test isfile(path)

    handle = LibRawWrapper.libraw_init(0)
    @test handle != C_NULL
    try
        open_code = LibRawWrapper.libraw_open_file(handle, path)
        @test open_code == 0

        unpack_code = LibRawWrapper.libraw_unpack(handle)
        @test unpack_code == 0
        @test LibRawWrapper.libraw_get_raw_width(handle) == 8288
        @test LibRawWrapper.libraw_get_raw_height(handle) == 5520
        @test LibRawWrapper.libraw_get_iwidth(handle) == 8288
        @test LibRawWrapper.libraw_get_iheight(handle) == 5520

        rgb_cam =
            [LibRawWrapper.libraw_get_rgb_cam(handle, row, col) for row = 0:2, col = 0:3]
        @test all(isfinite, rgb_cam)
        @test any(!iszero, rgb_cam)
        @info "camera RGB-to-camera matrix coefficients" rgb_cam
    finally
        LibRawWrapper.libraw_close(handle)
    end
end

@testset "Examples" begin
    root = dirname(@__DIR__)
    fixture = joinpath(@__DIR__, "data", "test.nef")
    examples = [
        ("highlevel.jl", String[]),
        ("identify.jl", [fixture]),
        ("metadata.jl", [fixture]),
        ("unprocessed.jl", [fixture]),
        ("process.jl", [fixture]),
        ("buffer.jl", [fixture]),
        ("raw_api.jl", [fixture]),
    ]
    mktempdir() do output_dir
        push!(examples, ("thumbnail.jl", [fixture, joinpath(output_dir, "thumbnail.bin")]))
        for (name, args) in examples
            script = joinpath(root, "examples", name)
            cmd = `$((Base.julia_cmd())) --project=$root $script $args`
            run(Cmd(cmd; dir = output_dir))
        end
        @test isfile(joinpath(output_dir, "processed.ppm"))
        @test isfile(joinpath(output_dir, "thumbnail.bin"))
    end
end
