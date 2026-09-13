using LibRawWrapper

path = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "data", "test.nef"))
bytes = read(path)
p = LibRawProcessor()
try
    open!(p, bytes) # the processor retains `bytes` while LibRaw reads it
    unpack!(p)
    println(metadata(p))
finally
    close!(p)
end
