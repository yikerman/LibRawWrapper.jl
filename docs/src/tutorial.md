# Build a small RAW processor

Build a RAW processor that normalizes sensor samples, applies camera white
balance, combines Bayer tiles into RGB pixels, and adjusts color and brightness.

This tutorial uses a Nikon D850 photograph from the repository and requires
Julia 1.12 or later and `wget`.

## Create the project and download a photograph

```sh
mkdir my-rawproc
cd my-rawproc
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/yikerman/LibRawWrapper.jl.git")'
wget -O test.nef https://media.githubusercontent.com/media/yikerman/LibRawWrapper.jl/master/test/data/test.nef
```

The photograph is about 47 MB.

## Read the sensor and its calibration

In `process.jl`, copy the visible sensor region and its calibration:

```julia
using LibRawWrapper
using LinearAlgebra

sensor, calibration, info = openraw("test.nef") do raw
    sensor_image(raw; visible=true), color_data(raw), metadata(raw)
end
println("Camera: ", info.model)
println("Sensor: ", size(sensor.data))

@assert sensor.layout isa CFALayout
@assert sensor.layout.kind == Bayer
@assert sensor.layout.channel_labels == "RGBG"
@assert cfa_pattern(sensor) == UInt8[1 2; 4 3]
@assert all(iseven, size(sensor.data))
println("CFA: RGGB")
```

The sample has an RGGB Bayer layout:

```text
Camera: D850
Sensor: (5520, 8288)
CFA: RGGB
```

The copies remain valid after `openraw` closes the processor. Each Bayer tile
has red at the top left, blue at the bottom right, and two green samples. The
following processing steps assume this layout.

## Normalize the sensor values

Subtract the black offset and divide by the range between black and saturation:

```julia
@assert isempty(calibration.spatial_black)
black = Float32(calibration.black) + sum(Float32.(calibration.channel_black)) / 4f0
white = Float32(calibration.maximum)
@assert white > black
bayer = clamp.((Float32.(sensor.data) .- black) ./ (white - black), 0f0, 1f0)
println("Black and white: ", (black, white))
```

The sample's black and white levels are `(400.0f0, 16383.0f0)`, which map to
zero and one. This uses the mean channel black offset and assumes no spatial
black pattern.

## Apply the camera white balance

Normalize the camera's channel multipliers by their average green value. Apply
them to the four positions of each Bayer tile:

```julia
wb = collect(calibration.cam_mul)
@assert all(x -> isfinite(x) && x > 0, wb)
green = (wb[2] + wb[4]) / 2f0
wb ./= green

function balance_rggb!(bayer, wb)
    @views begin
        bayer[1:2:end, 1:2:end] .*= wb[1]
        bayer[1:2:end, 2:2:end] .*= wb[2]
        bayer[2:2:end, 1:2:end] .*= wb[4]
        bayer[2:2:end, 2:2:end] .*= wb[3]
    end
    bayer
end

balance_rggb!(bayer, wb)
println("White balance: ", wb)
```

The multipliers are approximately `[1.8442, 1.0, 1.3838, 1.0]` in `RGBG` order,
raising red and blue relative to green. Keep values above one until the final
clipping step to preserve highlight detail through the color conversion.

## Combine each 2×2 tile into one RGB pixel

Take red and blue from their tile positions and average the two greens:

```julia
function bin_rggb(bayer)
    red = bayer[1:2:end, 1:2:end]
    green = (bayer[1:2:end, 2:2:end] .+ bayer[2:2:end, 1:2:end]) ./ 2f0
    blue = bayer[2:2:end, 2:2:end]
    cat(red, green, blue; dims=3)
end

camera_rgb = bin_rggb(bayer)
println("Binned RGB: ", size(camera_rgb))
```

The result has size `(2760, 4144, 3)`: half the sensor's height and width, with
three channels. Binning trades spatial resolution for a simple reconstruction.

## Convert camera RGB to linear sRGB

LibRaw derives a camera-to-sRGB matrix from the file's calibration. Its fourth
column is zero for this sample, so use the first three columns:

```julia
@assert all(iszero, calibration.rgb_cam[:, 4])
cam_to_srgb = calibration.rgb_cam[:, 1:3]
pixels = reshape(camera_rgb, :, 3)
linear_rgb = reshape(pixels * transpose(cam_to_srgb), size(camera_rgb))
```

The transpose applies the matrix to RGB triplets stored as rows. The resulting
linear sRGB values can fall below zero or above one.

## Adjust brightness and apply display gamma

Scale the mean linear luminance to 0.25, an artistic brightness choice for
this preview, then apply a power curve:

```julia
luminance = 0.2126f0 .* linear_rgb[:, :, 1] .+
            0.7152f0 .* linear_rgb[:, :, 2] .+
            0.0722f0 .* linear_rgb[:, :, 3]
brightness = 0.25f0 / max(sum(luminance) / length(luminance), eps(Float32))
bright_rgb = linear_rgb .* brightness
display_rgb = clamp.(max.(bright_rgb, 0f0) .^ (1f0 / 2.2f0), 0f0, 1f0)
```

The `1/2.2` power approximates the sRGB transfer curve. Final clipping discards
highlight detail above one before conversion to 8-bit output.

## Save and view the result

PPM stores each pixel's RGB bytes consecutively:

```julia
function save_ppm(path, rgb)
    height, width, channels = size(rgb)
    @assert channels == 3
    bytes = round.(UInt8, 255f0 .* rgb)
    open(path, "w") do io
        write(io, "P6\n$(width) $(height)\n255\n")
        for row in 1:height, col in 1:width, channel in 1:3
            write(io, bytes[row, col, channel])
        end
    end
end

save_ppm("processed.ppm", display_rgb)
println("Wrote processed.ppm (4144 × 2760)")
```

```sh
julia --project=. process.jl
```

Open `processed.ppm` in an image viewer that supports PPM. It contains a
4144 × 2760 color photograph.

For LibRaw's built-in renderer, including full-resolution demosaicing, continue
with [Render with explicit settings](@ref). For background on the data used
here, see [Sensor samples, working buffers, and rendered images](@ref image-stages).
