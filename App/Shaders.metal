//
//  Shaders.metal
//  One pass, raw USB payload -> drawable. The fragment shader reads the sensor bytes
//  directly from the shared frame buffer (no upload, no intermediate texture) and
//  demosaics / normalises on the fly.
//

#include <metal_stdlib>
using namespace metal;

// Keep in sync with FrameRenderer.swift
enum PixelKind : uint {
    kMono   = 0,
    kBayer  = 1,
    kRGB    = 2,
    kBGR    = 3,
};

struct FrameParams {
    uint  width;
    uint  height;
    uint  stride;          // bytes per line including padding
    uint  kind;
    uint  bytesPerSample;  // 1 or 2
    uint  redX;            // Bayer: position of the red sample in the 2x2 tile
    uint  redY;
    float scale;           // 1 / max sample value
    float2 quadScale;      // aspect-fit in NDC
    float gamma;
    float pad;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut frame_vertex(uint vid [[vertex_id]], constant FrameParams &p [[buffer(0)]])
{
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[vid];
    VertexOut out;
    out.position = float4(c * p.quadScale, 0, 1);
    out.uv = float2((c.x + 1) * 0.5, (1 - c.y) * 0.5);
    return out;
}

static inline float sample_at(device const uchar *raw, constant FrameParams &p, int x, int y)
{
    x = clamp(x, 0, int(p.width) - 1);
    y = clamp(y, 0, int(p.height) - 1);
    uint offset = uint(y) * p.stride + uint(x) * p.bytesPerSample;
    if (p.bytesPerSample == 1) {
        return float(raw[offset]) * p.scale;
    }
    return float(uint(raw[offset]) | (uint(raw[offset + 1]) << 8)) * p.scale;
}

static inline float3 demosaic(device const uchar *raw, constant FrameParams &p, int x, int y)
{
    float c = sample_at(raw, p, x, y);
    float cross = 0.25 * (sample_at(raw, p, x - 1, y) + sample_at(raw, p, x + 1, y) +
                          sample_at(raw, p, x, y - 1) + sample_at(raw, p, x, y + 1));
    float diag = 0.25 * (sample_at(raw, p, x - 1, y - 1) + sample_at(raw, p, x + 1, y - 1) +
                         sample_at(raw, p, x - 1, y + 1) + sample_at(raw, p, x + 1, y + 1));
    float horiz = 0.5 * (sample_at(raw, p, x - 1, y) + sample_at(raw, p, x + 1, y));
    float vert = 0.5 * (sample_at(raw, p, x, y - 1) + sample_at(raw, p, x, y + 1));

    bool onRedRow = (uint(y) & 1) == p.redY;
    bool onRedCol = (uint(x) & 1) == p.redX;
    if (onRedRow && onRedCol)   return float3(c, cross, diag);        // red site
    if (!onRedRow && !onRedCol) return float3(diag, cross, c);        // blue site
    if (onRedRow)               return float3(horiz, c, vert);        // green on red row
    return float3(vert, c, horiz);                                    // green on blue row
}

fragment float4 frame_fragment(VertexOut in [[stage_in]],
                               device const uchar *raw [[buffer(0)]],
                               constant FrameParams &p [[buffer(1)]])
{
    int x = int(in.uv.x * float(p.width));
    int y = int(in.uv.y * float(p.height));
    float3 rgb;
    switch (p.kind) {
        case kBayer:
            rgb = demosaic(raw, p, x, y);
            break;
        case kRGB:
        case kBGR: {
            x = clamp(x, 0, int(p.width) - 1);
            y = clamp(y, 0, int(p.height) - 1);
            uint o = uint(y) * p.stride + uint(x) * 3;
            float3 v = float3(raw[o], raw[o + 1], raw[o + 2]) * p.scale;
            rgb = p.kind == kRGB ? v : v.bgr;
            break;
        }
        default:
            rgb = float3(sample_at(raw, p, x, y));
            break;
    }
    rgb = pow(saturate(rgb), float3(p.gamma));
    return float4(rgb, 1);
}
