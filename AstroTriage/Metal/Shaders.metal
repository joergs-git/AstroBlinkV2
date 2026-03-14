// v3.2.0
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

// ==========================================================================
// GPU bilinear warp + accumulate for Quick Stack V2
// Backward-maps each destination pixel through an affine inverse transform,
// reads source with bilinear interpolation, writes to float accumulator.
// One dispatch per frame — massively parallel (one thread per output pixel).
// ==========================================================================

struct AffineParams {
    float a, b, tx;     // Row 1: x' = a*x + b*y + tx
    float c, d, ty;     // Row 2: y' = c*x + d*y + ty
};

kernel void warp_accumulate(
    device const uint16_t* source [[buffer(0)]],
    device float* accumulator [[buffer(1)]],
    device float* weights [[buffer(2)]],
    constant AffineParams& invTransform [[buffer(3)]],
    constant int& width [[buffer(4)]],
    constant int& height [[buffer(5)]],
    constant int& channelCount [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]])
{
    if ((int)gid.x >= width || (int)gid.y >= height) return;

    int w = width;
    int h = height;
    int planeSize = w * h;

    // Backward map: destination → source coordinate
    float sx = invTransform.a * float(gid.x) + invTransform.b * float(gid.y) + invTransform.tx;
    float sy = invTransform.c * float(gid.x) + invTransform.d * float(gid.y) + invTransform.ty;

    // Bounds check with 1px margin for bilinear
    if (sx < 0.0 || sx >= float(w - 1) || sy < 0.0 || sy >= float(h - 1)) return;

    // Bilinear interpolation weights
    int ix = int(sx);
    int iy = int(sy);
    float fx = sx - float(ix);
    float fy = sy - float(iy);
    float w00 = (1.0 - fx) * (1.0 - fy);
    float w10 = fx * (1.0 - fy);
    float w01 = (1.0 - fx) * fy;
    float w11 = fx * fy;

    int dstIdx = int(gid.y) * w + int(gid.x);

    for (int ch = 0; ch < channelCount; ch++) {
        int chOff = ch * planeSize;
        float v = float(source[chOff + iy * w + ix])       * w00
                + float(source[chOff + iy * w + ix + 1])   * w10
                + float(source[chOff + (iy + 1) * w + ix]) * w01
                + float(source[chOff + (iy + 1) * w + ix + 1]) * w11;
        accumulator[ch * planeSize + dstIdx] += v;
    }

    weights[dstIdx] += 1.0;
}

// ==========================================================================
// Post-processing: combined sharpening + contrast + dark level adjustment
// Operates on already-stretched BGRA8 textures for real-time adjustments
// Single pass: read input → apply dark level → contrast → sharpen → write output
// ==========================================================================

struct PostProcessParams {
    float sharpening;   // 0 = off, 0–2 = mild to strong
    float contrast;     // -1 to 1 (0 = off), S-curve intensity
    float darkLevel;    // 0–0.5, shadows clip threshold
};

kernel void post_process(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant PostProcessParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float4 color = input.read(gid);

    // Step 1: Dark level — clip shadows and rescale
    if (params.darkLevel > 0.0) {
        float dl = params.darkLevel;
        float inv = 1.0 / (1.0 - dl);
        color.r = clamp((color.r - dl) * inv, 0.0, 1.0);
        color.g = clamp((color.g - dl) * inv, 0.0, 1.0);
        color.b = clamp((color.b - dl) * inv, 0.0, 1.0);
    }

    // Step 2: Contrast — S-curve around midpoint 0.5
    if (params.contrast != 0.0) {
        float c = 1.0 + params.contrast;
        color.r = clamp(0.5 + (color.r - 0.5) * c, 0.0, 1.0);
        color.g = clamp(0.5 + (color.g - 0.5) * c, 0.0, 1.0);
        color.b = clamp(0.5 + (color.b - 0.5) * c, 0.0, 1.0);
    }

    // Step 3: Sharpening (positive) or Blur (negative) — 3x3 kernel
    if (params.sharpening != 0.0) {
        int w = (int)input.get_width();
        int h = (int)input.get_height();
        int x = (int)gid.x;
        int y = (int)gid.y;

        // Only sharpen interior pixels (skip 1px border)
        if (x > 0 && x < w - 1 && y > 0 && y < h - 1) {
            // Read 3x3 neighborhood for blur estimate
            float4 n  = input.read(uint2(x, y - 1));
            float4 s  = input.read(uint2(x, y + 1));
            float4 e  = input.read(uint2(x + 1, y));
            float4 w4 = input.read(uint2(x - 1, y));

            // Average of 4-connected neighbors (Laplacian approximation)
            float4 blur = (n + s + e + w4) * 0.25;

            // Apply dark level and contrast to blur sample too for consistency
            if (params.darkLevel > 0.0) {
                float dl = params.darkLevel;
                float inv = 1.0 / (1.0 - dl);
                blur.r = clamp((blur.r - dl) * inv, 0.0, 1.0);
                blur.g = clamp((blur.g - dl) * inv, 0.0, 1.0);
                blur.b = clamp((blur.b - dl) * inv, 0.0, 1.0);
            }
            if (params.contrast != 0.0) {
                float c = 1.0 + params.contrast;
                blur.r = clamp(0.5 + (blur.r - 0.5) * c, 0.0, 1.0);
                blur.g = clamp(0.5 + (blur.g - 0.5) * c, 0.0, 1.0);
                blur.b = clamp(0.5 + (blur.b - 0.5) * c, 0.0, 1.0);
            }

            // Positive: unsharp mask (sharpen). Negative: mix towards blur (soften).
            // sharpened = original + amount * (original - blur)
            // When amount < 0: effectively blends original towards the blurred version
            float amount = params.sharpening;
            color.r = clamp(color.r + amount * (color.r - blur.r), 0.0, 1.0);
            color.g = clamp(color.g + amount * (color.g - blur.g), 0.0, 1.0);
            color.b = clamp(color.b + amount * (color.b - blur.b), 0.0, 1.0);
        }
    }

    output.write(color, gid);
}

// ==========================================================================
// GPU Star Detection — threshold + 3x3 local maxima on binned uint16 data
// Operates on the bin2x output buffer (already computed during prefetch).
// Candidates are atomically appended to an output buffer for CPU readback.
// ==========================================================================

struct StarCandidate {
    uint x;      // Binned pixel x coordinate
    uint y;      // Binned pixel y coordinate
    float value; // Background-subtracted brightness
};

kernel void detect_stars_binned(
    device const uint16_t* binnedData  [[buffer(0)]],
    device StarCandidate* candidates   [[buffer(1)]],
    device atomic_uint* candidateCount [[buffer(2)]],
    constant int& width                [[buffer(3)]],
    constant int& height               [[buffer(4)]],
    constant float& threshold          [[buffer(5)]],
    constant float& median             [[buffer(6)]],
    constant int& channel              [[buffer(7)]],
    constant int& channelCount         [[buffer(8)]],
    constant int& maxCandidates        [[buffer(9)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = width;
    int h = height;
    if ((int)gid.x >= w || (int)gid.y >= h) return;

    // Border exclusion: skip 3px from edge (need 1px neighborhood + margin)
    int x = (int)gid.x;
    int y = (int)gid.y;
    if (x < 3 || x >= w - 3 || y < 3 || y >= h - 3) return;

    // Read pixel from selected channel
    int planeSize = w * h;
    int ch = min(channel, channelCount - 1);
    int idx = ch * planeSize + y * w + x;
    float val = float(binnedData[idx]);

    // Threshold check
    if (val <= threshold) return;

    // 3x3 local maximum check (strict: must be greater than all neighbors)
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int nIdx = ch * planeSize + (y + dy) * w + (x + dx);
            if (float(binnedData[nIdx]) >= val) return;
        }
    }

    // Atomic append to candidate buffer (capped at maxCandidates)
    uint slot = atomic_fetch_add_explicit(candidateCount, 1, memory_order_relaxed);
    if (slot < (uint)maxCandidates) {
        StarCandidate c;
        c.x = (uint)x;
        c.y = (uint)y;
        c.value = val - median;
        candidates[slot] = c;
    }
}

// ==========================================================================
// Restretch Float — GPU-accelerated STF + post-process for stacked result
// Input: float buffer (planar, normalized to 0–65535 range)
// Output: BGRA8 texture
// Combines STF stretch + dark level + contrast + sharpening in one pass
// ==========================================================================

struct RestretchParams {
    float c0;           // STF shadows clipping point (channel 0 / mono / linked)
    float mb;           // STF midtone balance (channel 0 / mono / linked)
    float darkLevel;    // 0–1, shadows clip
    float contrast;     // -2 to 2
    float sharpening;   // -4 to 4
    int width;
    int height;
    int channelCount;
    float saturation;   // 0–3, 1.0 = neutral, <1 desaturate, >1 boost color
    float c0_g;         // Per-channel STF for unlinked RGB stretch
    float mb_g;
    float c0_b;
    float mb_b;
};

kernel void restretch_float(
    device const float* data [[buffer(0)]],
    texture2d<float, access::write> output [[texture(0)]],
    constant RestretchParams& params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if ((int)gid.x >= params.width || (int)gid.y >= params.height) return;

    int idx = (int)gid.y * params.width + (int)gid.x;
    int planeSize = params.width * params.height;
    float c0 = params.c0;
    float mb = params.mb;
    float rangeInv = 1.0 / max(1.0 - c0, 0.001);

    // Read and stretch per channel
    float r, g, b;
    if (params.channelCount == 1) {
        float v = data[idx] / 65535.0;
        v = clamp((v - c0) * rangeInv, 0.0, 1.0);
        v = mtf(v, mb);
        r = g = b = v;
    } else {
        r = data[idx] / 65535.0;
        g = data[planeSize + idx] / 65535.0;
        b = data[2 * planeSize + idx] / 65535.0;
        // Per-channel (unlinked) STF stretch for proper RGB color balance
        float c0_g = params.c0_g;
        float c0_b = params.c0_b;
        float mb_g = params.mb_g;
        float mb_b = params.mb_b;
        r = clamp((r - c0) * rangeInv, 0.0, 1.0); r = mtf(r, mb);
        float rangeInvG = 1.0 / max(1.0 - c0_g, 0.001);
        g = clamp((g - c0_g) * rangeInvG, 0.0, 1.0); g = mtf(g, mb_g);
        float rangeInvB = 1.0 / max(1.0 - c0_b, 0.001);
        b = clamp((b - c0_b) * rangeInvB, 0.0, 1.0); b = mtf(b, mb_b);
    }

    // Dark level
    if (params.darkLevel > 0.0) {
        float dl = params.darkLevel;
        float inv = 1.0 / max(1.0 - dl, 0.001);
        r = clamp((r - dl) * inv, 0.0, 1.0);
        g = clamp((g - dl) * inv, 0.0, 1.0);
        b = clamp((b - dl) * inv, 0.0, 1.0);
    }

    // Contrast
    if (params.contrast != 0.0) {
        float c = 1.0 + params.contrast;
        r = clamp(0.5 + (r - 0.5) * c, 0.0, 1.0);
        g = clamp(0.5 + (g - 0.5) * c, 0.0, 1.0);
        b = clamp(0.5 + (b - 0.5) * c, 0.0, 1.0);
    }

    // Sharpening (unsharp mask using 4-connected neighbors)
    if (params.sharpening != 0.0) {
        int x = (int)gid.x;
        int y = (int)gid.y;
        if (x > 0 && x < params.width - 1 && y > 0 && y < params.height - 1) {
            // Read neighbor values and apply same stretch pipeline
            float amount = params.sharpening;
            // For each channel, compute blur from stretched neighbors
            for (int ch = 0; ch < (params.channelCount == 1 ? 1 : 3); ch++) {
                int chOff = ch * planeSize;
                if (params.channelCount == 1) chOff = 0;

                float vn = data[chOff + (y-1) * params.width + x] / 65535.0;
                float vs = data[chOff + (y+1) * params.width + x] / 65535.0;
                float ve = data[chOff + y * params.width + (x+1)] / 65535.0;
                float vw = data[chOff + y * params.width + (x-1)] / 65535.0;

                // Stretch neighbors (per-channel for RGB)
                float ch_c0 = (ch == 0) ? c0 : (ch == 1) ? params.c0_g : params.c0_b;
                float ch_mb = (ch == 0) ? mb : (ch == 1) ? params.mb_g : params.mb_b;
                float ch_rangeInv = 1.0 / max(1.0 - ch_c0, 0.001);
                if (params.channelCount == 1) { ch_c0 = c0; ch_mb = mb; ch_rangeInv = rangeInv; }
                vn = clamp((vn - ch_c0) * ch_rangeInv, 0.0, 1.0); vn = mtf(vn, ch_mb);
                vs = clamp((vs - ch_c0) * ch_rangeInv, 0.0, 1.0); vs = mtf(vs, ch_mb);
                ve = clamp((ve - ch_c0) * ch_rangeInv, 0.0, 1.0); ve = mtf(ve, ch_mb);
                vw = clamp((vw - ch_c0) * ch_rangeInv, 0.0, 1.0); vw = mtf(vw, ch_mb);

                // Apply dark + contrast to neighbors too
                if (params.darkLevel > 0.0) {
                    float dl = params.darkLevel;
                    float inv2 = 1.0 / max(1.0 - dl, 0.001);
                    vn = clamp((vn - dl) * inv2, 0.0, 1.0);
                    vs = clamp((vs - dl) * inv2, 0.0, 1.0);
                    ve = clamp((ve - dl) * inv2, 0.0, 1.0);
                    vw = clamp((vw - dl) * inv2, 0.0, 1.0);
                }
                if (params.contrast != 0.0) {
                    float cc = 1.0 + params.contrast;
                    vn = clamp(0.5 + (vn - 0.5) * cc, 0.0, 1.0);
                    vs = clamp(0.5 + (vs - 0.5) * cc, 0.0, 1.0);
                    ve = clamp(0.5 + (ve - 0.5) * cc, 0.0, 1.0);
                    vw = clamp(0.5 + (vw - 0.5) * cc, 0.0, 1.0);
                }

                float blur = (vn + vs + ve + vw) * 0.25;
                if (ch == 0) r = clamp(r + amount * (r - blur), 0.0, 1.0);
                else if (ch == 1) g = clamp(g + amount * (g - blur), 0.0, 1.0);
                else b = clamp(b + amount * (b - blur), 0.0, 1.0);
            }
            // For mono, replicate
            if (params.channelCount == 1) { g = r; b = r; }
        }
    }

    // Saturation (only for RGB; mono has no color to saturate)
    if (params.channelCount > 1 && params.saturation != 1.0) {
        float lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        float s = params.saturation;
        r = clamp(lum + s * (r - lum), 0.0, 1.0);
        g = clamp(lum + s * (g - lum), 0.0, 1.0);
        b = clamp(lum + s * (b - lum), 0.0, 1.0);
    }

    output.write(float4(r, g, b, 1.0), gid);
}

// ==========================================================================
// Bilateral Denoise — edge-preserving noise reduction on RGBA8 texture
// Spatial Gaussian + intensity Gaussian → smooths noise, preserves edges/stars
// Single-pass, runs on the stretched output texture
// ==========================================================================

struct DenoiseParams {
    float strength;     // 0–1, controls intensity sigma (0 = off, 1 = aggressive)
    int width;
    int height;
    int radius;         // Kernel radius (typically 3–5)
};

kernel void bilateral_denoise(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant DenoiseParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if ((int)gid.x >= params.width || (int)gid.y >= params.height) return;

    float4 center = input.read(gid);
    int r = params.radius;

    // Spatial sigma scales with radius; intensity sigma scales with strength
    float sigmaSpatial = float(r) * 0.5;
    float sigmaIntensity = 0.02 + params.strength * 0.15;  // 0.02–0.17 range

    float invSpatial2 = -0.5 / (sigmaSpatial * sigmaSpatial);
    float invIntensity2 = -0.5 / (sigmaIntensity * sigmaIntensity);

    float3 sumColor = float3(0.0);
    float sumWeight = 0.0;

    for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
            int nx = (int)gid.x + dx;
            int ny = (int)gid.y + dy;

            // Clamp to image bounds
            nx = clamp(nx, 0, params.width - 1);
            ny = clamp(ny, 0, params.height - 1);

            float4 neighbor = input.read(uint2(nx, ny));

            // Spatial weight (Gaussian distance)
            float dist2 = float(dx * dx + dy * dy);
            float ws = exp(dist2 * invSpatial2);

            // Intensity weight (Gaussian color difference)
            float3 diff = neighbor.rgb - center.rgb;
            float colorDist2 = dot(diff, diff);
            float wi = exp(colorDist2 * invIntensity2);

            float w = ws * wi;
            sumColor += neighbor.rgb * w;
            sumWeight += w;
        }
    }

    float3 result = sumWeight > 0.0 ? sumColor / sumWeight : center.rgb;
    output.write(float4(result, 1.0), gid);
}

// ==========================================================================
// Chrominance Denoise — removes color noise (green/magenta patches) while
// preserving luminance detail. Works in YCbCr space: blurs only Cb/Cr
// with a spatial Gaussian, keeps Y (brightness) untouched.
// ==========================================================================

kernel void chroma_denoise(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant DenoiseParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if ((int)gid.x >= params.width || (int)gid.y >= params.height) return;

    float4 center = input.read(gid);

    // RGB → YCbCr (Rec.709)
    float Y  =  0.2126 * center.r + 0.7152 * center.g + 0.0722 * center.b;
    float Cb = -0.1146 * center.r - 0.3854 * center.g + 0.5000 * center.b;
    float Cr =  0.5000 * center.r - 0.4542 * center.g - 0.0458 * center.b;

    // Gaussian blur on Cb/Cr only (larger radius than luminance denoise)
    int r = params.radius + 2;  // Wider kernel for color noise
    float sigma = float(r) * 0.6;
    float invSigma2 = -0.5 / (sigma * sigma);

    float sumCb = 0.0, sumCr = 0.0, sumW = 0.0;

    for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
            int nx = clamp((int)gid.x + dx, 0, params.width - 1);
            int ny = clamp((int)gid.y + dy, 0, params.height - 1);
            float4 n = input.read(uint2(nx, ny));

            float dist2 = float(dx * dx + dy * dy);
            float w = exp(dist2 * invSigma2);

            float nCb = -0.1146 * n.r - 0.3854 * n.g + 0.5000 * n.b;
            float nCr =  0.5000 * n.r - 0.4542 * n.g - 0.0458 * n.b;

            sumCb += nCb * w;
            sumCr += nCr * w;
            sumW += w;
        }
    }

    // Blended chrominance (mix original and blurred based on strength)
    float s = params.strength;
    float blurCb = sumW > 0.0 ? sumCb / sumW : Cb;
    float blurCr = sumW > 0.0 ? sumCr / sumW : Cr;
    Cb = mix(Cb, blurCb, s);
    Cr = mix(Cr, blurCr, s);

    // YCbCr → RGB
    float rr = Y + 1.5748 * Cr;
    float gg = Y - 0.1873 * Cb - 0.4681 * Cr;
    float bb = Y + 1.8556 * Cb;

    output.write(float4(clamp(rr, 0.0, 1.0), clamp(gg, 0.0, 1.0), clamp(bb, 0.0, 1.0), 1.0), gid);
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
