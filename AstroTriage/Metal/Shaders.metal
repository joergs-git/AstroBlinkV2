// v2.0.0
// STF Auto-Stretch + Debayer: PixInsight-compatible Screen Transfer Function
// Applies per-channel Midtones Transfer Function for proper astro visualization
// Includes bilinear debayer kernel for OSC (one-shot color) cameras

#include <metal_stdlib>
using namespace metal;

// Midtones Transfer Function (MTF)
// Maps [0,1] → [0,1] with midtone balance point m
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

// Normalize uint16 with STF auto-stretch to BGRA8 for display
// Input: uint16 buffer (planar if multi-channel)
// Output: BGRA8 texture
kernel void normalize_uint16(
    device const uint16_t* pixelData [[buffer(0)]],
    texture2d<float, access::write> output [[texture(0)]],
    constant int& width [[buffer(1)]],
    constant int& height [[buffer(2)]],
    constant int& channelCount [[buffer(3)]],
    constant STFParams* stfParams [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= (uint)width || gid.y >= (uint)height) return;

    uint pixelIndex = gid.y * (uint)width + gid.x;
    uint planeSize = (uint)width * (uint)height;

    float4 color;

    if (channelCount == 1) {
        // Mono: apply single-channel STF
        float v = float(pixelData[pixelIndex]) / 65535.0;
        float c0 = stfParams[0].c0;
        float mb = stfParams[0].mb;
        // Clip shadows and rescale
        v = clamp((v - c0) / (1.0 - c0), 0.0, 1.0);
        v = mtf(v, mb);
        color = float4(v, v, v, 1.0);
    } else if (channelCount == 3) {
        // RGB planar: apply per-channel STF (unlinked for OSC data)
        float r = float(pixelData[pixelIndex]) / 65535.0;
        float g = float(pixelData[planeSize + pixelIndex]) / 65535.0;
        float b = float(pixelData[2 * planeSize + pixelIndex]) / 65535.0;

        // Per-channel stretch
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
// Debayer — bilinear interpolation from mono Bayer CFA to RGB planar
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

    #define PIX(px, py) rawData[clamp((py), 0, h-1) * w + clamp((px), 0, w-1)]

    int px = x % 2;
    int py = y % 2;
    int pos = py * 2 + px;

    // Color at each position in the 2x2 Bayer tile: 0=R, 1=G, 2=B
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
        r = center;
        g = (float(PIX(x-1,y)) + float(PIX(x+1,y)) + float(PIX(x,y-1)) + float(PIX(x,y+1))) * 0.25;
        b = (float(PIX(x-1,y-1)) + float(PIX(x+1,y-1)) + float(PIX(x-1,y+1)) + float(PIX(x+1,y+1))) * 0.25;
    } else if (myColor == 2) {
        b = center;
        g = (float(PIX(x-1,y)) + float(PIX(x+1,y)) + float(PIX(x,y-1)) + float(PIX(x,y+1))) * 0.25;
        r = (float(PIX(x-1,y-1)) + float(PIX(x+1,y-1)) + float(PIX(x-1,y+1)) + float(PIX(x+1,y+1))) * 0.25;
    } else {
        g = center;
        int leftColor = colorMap[clamp(bayerPattern, 0, 3)][(py * 2 + ((px + 1) % 2))];
        if (leftColor == 0) {
            r = (float(PIX(x-1,y)) + float(PIX(x+1,y))) * 0.5;
            b = (float(PIX(x,y-1)) + float(PIX(x,y+1))) * 0.5;
        } else {
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
// GPU bin2x — average every 2x2 block for half-resolution downsampling
// Replaces CPU nested loops (~30-150ms) with GPU compute (~<1ms)
// Input/output: uint16 planar buffers (mono or multi-channel)
// ==========================================================================

kernel void bin2x(
    device const uint16_t* input [[buffer(0)]],
    device uint16_t* output [[buffer(1)]],
    constant int& srcWidth [[buffer(2)]],
    constant int& srcHeight [[buffer(3)]],
    constant int& channelCount [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    int dstW = srcWidth / 2;
    int dstH = srcHeight / 2;
    if ((int)gid.x >= dstW || (int)gid.y >= dstH) return;

    uint srcPlaneSize = (uint)srcWidth * (uint)srcHeight;
    uint dstPlaneSize = (uint)dstW * (uint)dstH;

    for (int ch = 0; ch < channelCount; ch++) {
        uint srcBase = ch * srcPlaneSize;
        uint dstBase = ch * dstPlaneSize;
        uint sx = gid.x * 2;
        uint sy = gid.y * 2;
        uint srcIdx = srcBase + sy * (uint)srcWidth + sx;
        uint sum = (uint)input[srcIdx]
                 + (uint)input[srcIdx + 1]
                 + (uint)input[srcIdx + (uint)srcWidth]
                 + (uint)input[srcIdx + (uint)srcWidth + 1];
        output[dstBase + gid.y * (uint)dstW + gid.x] = (uint16_t)(sum / 4);
    }
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
