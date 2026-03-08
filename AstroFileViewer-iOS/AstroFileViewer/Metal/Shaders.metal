// v1.3.0
// STF Auto-Stretch + Debayer + Sharpening kernels
// PixInsight-compatible Screen Transfer Function with adjustable stretch strength

#include <metal_stdlib>
using namespace metal;

// Midtones Transfer Function (MTF)
// Maps [0,1] -> [0,1] with midtone balance point m
inline float mtf(float x, float m) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    if (x == m) return 0.5;
    return (m - 1.0) * x / ((2.0 * m - 1.0) * x - m);
}

// STF parameters per channel: shadows clip (c0) and midtone balance (mb)
struct STFParams {
    float c0;   // Shadows clipping point [0,1]
    float mb;   // Midtone balance for MTF [0,1]
};

// ==========================================================================
// Kernel 1: STF normalize — uint16 mono/RGB to BGRA8
// ==========================================================================

kernel void normalize_uint16(
    device const uint16_t* pixelData [[buffer(0)]],
    texture2d<float, access::write> output [[texture(0)]],
    constant int& width [[buffer(1)]],
    constant int& height [[buffer(2)]],
    constant int& channelCount [[buffer(3)]],
    constant STFParams* stfParams [[buffer(4)]],
    constant int& binFactor [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint outW = output.get_width();
    uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    // Map output pixel back to source pixel using bin factor
    uint srcX = gid.x * (uint)binFactor;
    uint srcY = gid.y * (uint)binFactor;
    uint pixelIndex = srcY * (uint)width + srcX;
    uint planeSize = (uint)width * (uint)height;

    float4 color;

    if (channelCount == 1) {
        // Mono: apply single-channel STF
        float v = float(pixelData[pixelIndex]) / 65535.0;
        float c0 = stfParams[0].c0;
        float mb = stfParams[0].mb;
        v = clamp((v - c0) / (1.0 - c0), 0.0, 1.0);
        v = mtf(v, mb);
        color = float4(v, v, v, 1.0);
    } else if (channelCount == 3) {
        // RGB planar: apply per-channel STF (unlinked for OSC data)
        float r = float(pixelData[pixelIndex]) / 65535.0;
        float g = float(pixelData[planeSize + pixelIndex]) / 65535.0;
        float b = float(pixelData[2 * planeSize + pixelIndex]) / 65535.0;

        r = clamp((r - stfParams[0].c0) / (1.0 - stfParams[0].c0), 0.0, 1.0);
        r = mtf(r, stfParams[0].mb);
        g = clamp((g - stfParams[1].c0) / (1.0 - stfParams[1].c0), 0.0, 1.0);
        g = mtf(g, stfParams[1].mb);
        b = clamp((b - stfParams[2].c0) / (1.0 - stfParams[2].c0), 0.0, 1.0);
        b = mtf(b, stfParams[2].mb);

        color = float4(r, g, b, 1.0);
    } else {
        float v = float(pixelData[pixelIndex]) / 65535.0;
        float c0 = stfParams[0].c0;
        float mb = stfParams[0].mb;
        v = clamp((v - c0) / (1.0 - c0), 0.0, 1.0);
        v = mtf(v, mb);
        color = float4(v, v, v, 1.0);
    }

    output.write(color, gid);
}

// ==========================================================================
// Kernel 2: Debayer — bilinear interpolation from mono Bayer CFA to RGB planar
// Bayer patterns: 0=RGGB, 1=GRBG, 2=GBRG, 3=BGGR
// Output: 3-plane uint16 buffer (R, G, B planes in sequence)
// ==========================================================================

kernel void debayer_bilinear(
    device const uint16_t* rawData [[buffer(0)]],
    device uint16_t* rgbOut [[buffer(1)]],
    constant int& width [[buffer(2)]],
    constant int& height [[buffer(3)]],
    constant int& bayerPattern [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= (uint)width || gid.y >= (uint)height) return;

    int x = (int)gid.x;
    int y = (int)gid.y;
    int w = width;
    int h = height;
    uint planeSize = (uint)w * (uint)h;

    // Clamp helper
    #define PIX(px, py) rawData[clamp((py), 0, h-1) * w + clamp((px), 0, w-1)]

    // Determine which color this pixel is in the Bayer pattern
    // pattern encodes: top-left 2x2 = [TL, TR, BL, BR]
    // RGGB(0): R G / G B    GRBG(1): G R / B G
    // GBRG(2): G B / R G    BGGR(3): B G / G R
    int px = x % 2;  // 0=left, 1=right in 2x2 tile
    int py = y % 2;  // 0=top, 1=bottom in 2x2 tile
    int pos = py * 2 + px;

    // Map pattern index to color at each position
    // colorMap[pattern][pos] = 0(R), 1(G), 2(B)
    // RGGB: R=0, G=1, G=2, B=3 -> colors: [0,1,1,2]
    // GRBG: G=0, R=1, B=2, G=3 -> colors: [1,0,2,1]
    // GBRG: G=0, B=1, R=2, G=3 -> colors: [1,2,0,1]
    // BGGR: B=0, G=1, G=2, R=3 -> colors: [2,1,1,0]
    const int colorMap[4][4] = {
        {0, 1, 1, 2},  // RGGB
        {1, 0, 2, 1},  // GRBG
        {1, 2, 0, 1},  // GBRG
        {2, 1, 1, 0}   // BGGR
    };

    int myColor = colorMap[clamp(bayerPattern, 0, 3)][pos];

    float r, g, b;
    float center = float(PIX(x, y));

    if (myColor == 0) {
        // This pixel is Red
        r = center;
        // Green: average of 4 orthogonal neighbors
        g = (float(PIX(x-1,y)) + float(PIX(x+1,y)) + float(PIX(x,y-1)) + float(PIX(x,y+1))) * 0.25;
        // Blue: average of 4 diagonal neighbors
        b = (float(PIX(x-1,y-1)) + float(PIX(x+1,y-1)) + float(PIX(x-1,y+1)) + float(PIX(x+1,y+1))) * 0.25;
    } else if (myColor == 2) {
        // This pixel is Blue
        b = center;
        // Green: average of 4 orthogonal neighbors
        g = (float(PIX(x-1,y)) + float(PIX(x+1,y)) + float(PIX(x,y-1)) + float(PIX(x,y+1))) * 0.25;
        // Red: average of 4 diagonal neighbors
        r = (float(PIX(x-1,y-1)) + float(PIX(x+1,y-1)) + float(PIX(x-1,y+1)) + float(PIX(x+1,y+1))) * 0.25;
    } else {
        // This pixel is Green
        g = center;
        // Need to figure out if R or B neighbors are on same row or same column
        // For green at (px=1,py=0) or (px=0,py=1): red is horizontal neighbor
        // For green at (px=0,py=0) or (px=1,py=1): depends on pattern
        // Simpler approach: check which color is at (x-1,y) and (x,y-1)
        int leftColor = colorMap[clamp(bayerPattern, 0, 3)][(py * 2 + ((px + 1) % 2))];
        if (leftColor == 0) {
            // Red is on same row (left/right), Blue is on same column (up/down)
            r = (float(PIX(x-1,y)) + float(PIX(x+1,y))) * 0.5;
            b = (float(PIX(x,y-1)) + float(PIX(x,y+1))) * 0.5;
        } else {
            // Blue is on same row, Red is on same column
            b = (float(PIX(x-1,y)) + float(PIX(x+1,y))) * 0.5;
            r = (float(PIX(x,y-1)) + float(PIX(x,y+1))) * 0.5;
        }
    }

    #undef PIX

    uint idx = gid.y * (uint)w + gid.x;
    rgbOut[idx] = (uint16_t)clamp(r, 0.0f, 65535.0f);
    rgbOut[planeSize + idx] = (uint16_t)clamp(g, 0.0f, 65535.0f);
    rgbOut[2 * planeSize + idx] = (uint16_t)clamp(b, 0.0f, 65535.0f);
}

// ==========================================================================
// Kernel 3: Unsharp Mask — post-processing sharpening on BGRA8 texture
// Reads from input texture, writes sharpened result to output texture.
// Uses 3x3 Gaussian blur subtracted from original.
// ==========================================================================

kernel void unsharp_mask(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float& amount [[buffer(0)]],     // Sharpening strength [0..2]
    constant float& radius [[buffer(1)]],     // Not used for 3x3, reserved for future
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width();
    uint h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    // 3x3 Gaussian kernel weights (sigma ~0.85)
    // [1 2 1]
    // [2 4 2] / 16
    // [1 2 1]
    float4 sum = float4(0.0);
    const int offsets[3] = {-1, 0, 1};
    const float weights[3][3] = {
        {1.0/16.0, 2.0/16.0, 1.0/16.0},
        {2.0/16.0, 4.0/16.0, 2.0/16.0},
        {1.0/16.0, 2.0/16.0, 1.0/16.0}
    };

    for (int dy = 0; dy < 3; dy++) {
        for (int dx = 0; dx < 3; dx++) {
            int sx = clamp((int)gid.x + offsets[dx], 0, (int)w - 1);
            int sy = clamp((int)gid.y + offsets[dy], 0, (int)h - 1);
            sum += input.read(uint2(sx, sy)) * weights[dy][dx];
        }
    }

    float4 original = input.read(gid);
    // Unsharp mask: output = original + amount * (original - blurred)
    float4 sharpened = original + amount * (original - sum);
    sharpened = clamp(sharpened, 0.0, 1.0);
    sharpened.a = 1.0;

    output.write(sharpened, gid);
}

// MARK: - Textured Quad Shaders (for fit-to-view rendering with zoom/pan)

struct QuadVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader: pass through position and texcoord from vertex buffer
// Vertex data layout: [x, y, u, v] per vertex (4 floats, stride 16 bytes)
vertex QuadVertexOut quad_vertex(
    uint vid [[vertex_id]],
    device const float* vertices [[buffer(0)]])
{
    QuadVertexOut out;
    uint offset = vid * 4;
    out.position = float4(vertices[offset], vertices[offset + 1], 0.0, 1.0);
    out.texCoord = float2(vertices[offset + 2], vertices[offset + 3]);
    return out;
}

// Fragment shader: sample the normalized texture
fragment float4 quad_fragment(
    QuadVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]])
{
    return tex.sample(samp, in.texCoord);
}
