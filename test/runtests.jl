using Test
using LibRawWrapper

const FIXTURE = joinpath(@__DIR__, "data", "test.nef")

@testset "Metadata text bytes" begin
    chars = LibRawWrapper._chars
    @test chars(Tuple(reinterpret(Cchar, UInt8[0xc3, 0xa9, 0]))) == "é"
    @test chars((Cchar(0), Cchar(-1))) == ""
    @test chars((Cchar(65), Cchar(66))) == "AB"
    @test collect(codeunits(chars((Cchar(-1), Cchar(0))))) == UInt8[0xff]

    openraw(FIXTURE; unpack = false) do p
        # Exercise the public snapshot path with UTF-8 artist metadata.
        GC.@preserve p begin
            other = LibRawWrapper._fieldptr(p.handle, Val(:other))
            artist = LibRawWrapper._fieldptr(other, Val(:artist))
            bytes = collect(codeunits("José"))
            value = ntuple(
                i -> i <= length(bytes) ? reinterpret(Cchar, bytes[i]) : Cchar(0),
                fieldcount(eltype(typeof(artist))),
            )
            unsafe_store!(artist, value)
        end
        @test image_other(p).artist == "José"
        @test snapshot(p).other.artist == "José"
    end
end

@testset "Rendering and processor reuse" begin
    openraw(FIXTURE) do p
        original = image_sizes(p)
        params = ProcessingParams(
            output_type = UInt16,
            half_size = true,
            white_balance = CameraWB(),
            gamma = (1, 1),
            auto_bright = false,
        )
        first = postprocess!(p, params)
        @test eltype(first.data) == UInt16
        @test size(first.data) == (2760, 4144, 3)
        @test first.metadata.gamma == (1.0, 1.0)
        @test maximum(first.data) > minimum(first.data)
        full = postprocess!(p)
        @test eltype(full.data) == UInt8
        @test size(full.data) == (5520, 8288, 3)
        @test postprocess!(p, params).data == first.data

        open!(p, FIXTURE)
        unpack!(p)
        reopened = image_sizes(p)
        @test (reopened.iwidth, reopened.iheight) == (original.iwidth, original.iheight)
        @test (metadata(p).width, metadata(p).height) == (8288, 5520)
        @test postprocess!(p).data == full.data
        recycle!(p)
        @test p.state == Empty
        @test_throws ArgumentError processed_image(p)
        @test size(first.data) == (2760, 4144, 3)
    end
end

@testset "Lifecycle recovery and owned input" begin
    p = LibRawProcessor()
    try
        @test_throws ArgumentError unpack!(p)
        @test_throws ArgumentError process!(p)
        @test_throws ArgumentError open!(p, UInt8[])
        mktempdir() do dir
            @test_throws LibRawError open!(p, joinpath(dir, "missing.nef"))
        end
        @test_throws LibRawError open!(p, zeros(UInt8, 256))
        bytes = read(FIXTURE)
        open!(p, bytes)
        fill!(bytes, 0)
        GC.gc()
        unpack!(p)
        @test metadata(p).model == "D850"
        @test_throws ArgumentError unpack!(p)
        @test_throws ArgumentError processed_image(p)
        sensor = sensor_image(p)
        saved = copy(sensor.data[1:8, 1:8])
        close!(p)
        GC.gc()
        @test sensor.data[1:8, 1:8] == saved
        @test !isopen(p)
        @test_throws ArgumentError sensor_image(p)
        @test_throws ArgumentError open!(p, FIXTURE)
    finally
        close!(p)
    end
    open(FIXTURE) do io
        openraw(io; unpack = false) do q
            @test metadata(q).model == "D850"
        end
        @test isopen(io)
    end
    captured = Ref{LibRawProcessor}()
    @test_throws ErrorException openraw(FIXTURE; unpack = false) do q
        captured[] = q
        error("caller failure")
    end
    @test !isopen(captured[])
end

@testset "CFA phase and sensor crop" begin
    openraw(FIXTURE) do p
        full = sensor_image(p)
        visible = sensor_image(p; visible = true)
        s = image_sizes(p)
        @test visible.data == full.data[
            (s.top_margin+1):(s.top_margin+s.height),
            (s.left_margin+1):(s.left_margin+s.width),
        ]
        @test cfa_pattern(full) == UInt8[1 2; 4 3]
        @test color_index(full, 3, 4) == 2
        @test_throws BoundsError color_index(full, 0, 1)
        # A nonzero crop origin checks CFA phase even though this fixture has no margins.
        cropped = SensorImage(copy(full.data[2:5, 2:5]), full.layout, s, (2, 2))
        @test cfa_pattern(cropped) == UInt8[3 4; 2 1]
        @test color_indices(cropped) == UInt8[3 4 3 4; 2 1 2 1; 3 4 3 4; 2 1 2 1]
    end
end

@testset "Invalid rendering options" begin
    @test_throws ArgumentError ProcessingParams(output_type = Float32)
    @test_throws ArgumentError ProcessingParams(brightness = NaN)
    @test_throws ArgumentError ProcessingParams(gamma = (0, 1))
    @test_throws ArgumentError CustomWB((1, 1, 1))
    @test_throws ArgumentError CustomWB((1, 1, 1, -1))
end

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
