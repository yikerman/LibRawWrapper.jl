using Test

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

@testset "Examples" begin
    mktempdir() do output_dir
        push!(examples, ("thumbnail.jl", [fixture, joinpath(output_dir, "thumbnail.bin")]))
        for (name, args) in examples
            script = joinpath(root, "examples", name)
            run(Cmd(`$(Base.julia_cmd()) --project=$root $script $args`; dir = output_dir))
        end
        @test isfile(joinpath(output_dir, "processed.ppm"))
        @test isfile(joinpath(output_dir, "thumbnail.bin"))
    end
end
