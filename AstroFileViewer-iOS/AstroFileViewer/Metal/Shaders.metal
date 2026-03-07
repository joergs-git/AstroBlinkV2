// v0.5.0
// STF Auto-Stretch: PixInsight-compatible Screen Transfer Function
// Applies per-channel Midtones Transfer Function for proper astro visualization

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
