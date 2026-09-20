# Synthetic records cover metadata absent from the Nikon fixture without making
# LibRaw own Julia allocations. Each native pointer stays inside a preserve block.
function with_metadata_record(f, ::Type{T}) where {T}
    storage = zeros(UInt8, sizeof(T))
    GC.@preserve storage f(Ptr{T}(pointer(storage)))
end

function store_metadata_field!(ptr, name, value)
    field = LibRawWrapper._fieldptr(ptr, Val(name))
    unsafe_store!(field, convert(eltype(typeof(field)), value))
end

function owned_metadata(value)
    value isa AbstractDict && return all(owned_metadata, values(value))
    value isa AbstractArray && return all(owned_metadata, value)
    value === nothing || value isa Union{Number,AbstractString}
end

@testset "Owned vendor metadata" begin
    first, second = openraw(FIXTURE; unpack = false) do p
        a, b = snapshot(p), snapshot(p)
        @test a.maker_notes[:nikon][:PictureControlName] isa String
        @test !isempty(a.maker_notes[:nikon][:PictureControlName])
        @test a.maker_notes[:nikon][:PictureControlName] == "AUTO"
        @test a.maker_notes[:lens][:Lens] == lens_info(p).name
        @test a.dng[:version] == 0
        @test owned_metadata(a.maker_notes)
        @test owned_metadata(a.dng)
        recycle!(p)
        a, b
    end
    @test isequal(first.maker_notes, second.maker_notes)
    @test isequal(first.dng, second.dng)
    original = second.maker_notes[:nikon][:NEFBitDepth][1]
    first.maker_notes[:nikon][:NEFBitDepth][1] = original + 1
    @test second.maker_notes[:nikon][:NEFBitDepth][1] == original
    first.dng[:entries][1][:colormatrix][1][1] = 123
    @test second.dng[:entries][1][:colormatrix][1][1] != 123

    with_metadata_record(LibRawWrapper.libraw_makernotes_t) do ptr
        nikon = LibRawWrapper._fieldptr(ptr, Val(:nikon))
        name = LibRawWrapper._fieldptr(nikon, Val(:PictureControlName))
        text = collect(codeunits("Café\0ignored"))
        for (i, byte) in enumerate(text)
            unsafe_store!(Ptr{UInt8}(name), byte, i)
        end
        store_metadata_field!(nikon, :AFFineTuneAdj, -7)
        store_metadata_field!(nikon, :ImageStabilization, ntuple(i -> UInt8(i), 7))
        crop = LibRawWrapper._fieldptr(nikon, Val(:SensorHighSpeedCrop))
        store_metadata_field!(crop, :cwidth, 1234)
        sony = LibRawWrapper._fieldptr(ptr, Val(:sony))
        # A full text array without a NUL must still be bounded by its capacity.
        store_metadata_field!(sony, :MetaVersion, ntuple(_ -> Cchar(65), 16))
        result = LibRawWrapper._metadata_value(ptr)
        @test Set(keys(result)) == Set(fieldnames(LibRawWrapper.libraw_makernotes_t))
        @test result[:nikon][:PictureControlName] == "Café"
        @test result[:nikon][:AFFineTuneAdj] == -7
        @test result[:nikon][:ImageStabilization] == UInt8[1, 2, 3, 4, 5, 6, 7]
        @test result[:nikon][:SensorHighSpeedCrop][:cwidth] == 1234
        @test result[:sony][:MetaVersion] == "A"^16
        @test owned_metadata(result)
        unsafe_store!(Ptr{UInt8}(name), 0x00)
        @test result[:nikon][:PictureControlName] == "Café"
    end
end

@testset "DNG metadata arrays and flags" begin
    with_metadata_record(LibRawWrapper.libraw_dng_levels_t) do ptr
        flags = UInt32(LibRawWrapper.LibRawRaw.LIBRAW_DNGFM_BASELINEEXPOSURE)
        store_metadata_field!(ptr, :parsedfields, flags)
        store_metadata_field!(ptr, :baseline_exposure, -0.5)
        black = Ptr{UInt32}(LibRawWrapper._fieldptr(ptr, Val(:dng_cblack)))
        fblack = Ptr{Float32}(LibRawWrapper._fieldptr(ptr, Val(:dng_fcblack)))
        unsafe_store!(black, UInt32(777), 4104)
        unsafe_store!(fblack, 12.5f0, 4104)
        result = LibRawWrapper._metadata_value(ptr)
        @test result[:parsedfields] == flags
        @test result[:baseline_exposure] == -0.5f0
        @test length(result[:dng_cblack]) == 4104
        @test result[:dng_cblack][end] == 777
        @test result[:dng_fcblack][end] == 12.5f0
        @test length(result[:rawopcodes]) == 3
        @test all(x -> x[:data] === nothing, result[:rawopcodes])
        unsafe_store!(black, UInt32(0), 4104)
        @test result[:dng_cblack][end] == 777
    end
    with_metadata_record(LibRawWrapper.libraw_dng_color_t) do ptr
        matrix = LibRawWrapper._fieldptr(ptr, Val(:colormatrix))
        for i = 1:12
            unsafe_store!(Ptr{Float32}(matrix), Float32(i), i)
        end
        result = LibRawWrapper._metadata_value(ptr)
        @test result[:colormatrix] ==
              [Float32[1, 2, 3], Float32[4, 5, 6], Float32[7, 8, 9], Float32[10, 11, 12]]
    end
end

@testset "Metadata binary payload ownership" begin
    records = (
        (
            LibRawWrapper.libraw_nikon_makernotes_t,
            :BurstTable_0x0056,
            :BurstTable_0x0056_len,
        ),
        (LibRawWrapper.libraw_afinfo_item_t, :AFInfoData, :AFInfoData_length),
        (LibRawWrapper.libraw_dng_rawopcode_t, :data, :len),
    )
    for (T, datafield, lenfield) in records
        with_metadata_record(T) do ptr
            # Nikon can record a length without retaining the payload.
            store_metadata_field!(ptr, lenfield, 4)
            @test LibRawWrapper._metadata_value(ptr)[datafield] === nothing
            bytes = UInt8[0x00, 0x80, 0xff, 0x01]
            GC.@preserve bytes begin
                store_metadata_field!(ptr, datafield, pointer(bytes))
                result = LibRawWrapper._metadata_value(ptr)
                @test result[datafield] == bytes
                @test result[lenfield] == 4
                fill!(bytes, 0)
                @test result[datafield] == UInt8[0x00, 0x80, 0xff, 0x01]
                store_metadata_field!(ptr, lenfield, 0)
                @test LibRawWrapper._metadata_value(ptr)[datafield] == UInt8[]
            end
        end
    end
    @test_throws ArgumentError LibRawWrapper._metadata_bytes(Ptr{UInt8}(C_NULL), -1)
    @test_throws ArgumentError LibRawWrapper._metadata_bytes(
        Ptr{UInt8}(C_NULL),
        typemax(UInt),
    )
    @test_throws ArgumentError LibRawWrapper._metadata_value(Ptr{Ptr{UInt8}}(C_NULL))
end
