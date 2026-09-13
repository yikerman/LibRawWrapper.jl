using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
bytes = read(path)
openraw(bytes) do p # input is copied and retained while LibRaw reads it
    println(metadata(p))
end
