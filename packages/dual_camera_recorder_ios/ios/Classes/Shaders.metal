#include <metal_stdlib>
using namespace metal;

// Vertex passthrough for a textured quad. Position is in NDC; the inset MVP and
// mirror are baked into the texCoords on the CPU side.
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 local; // 0..1 within this quad, for the rounded-corner SDF
};

struct QuadUniforms {
    float4x4 mvp;      // places the quad (full-frame or inset) in NDC
    float     mirror;   // 1.0 -> flip x (front selfie)
    float     rounded;  // 1.0 -> apply rounded-corner SDF
    float2    quadSizePx;
    float     cornerRadiusPx;
    // BT.709 limited-range YCbCr -> RGB.
    float3x3  yuvMatrix;
    float3    yuvOffset;
};

vertex VertexOut dcr_vertex(uint vid [[vertex_id]],
                            constant QuadUniforms& u [[buffer(0)]]) {
    // Unit quad.
    float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 uv[4]  = { float2(0,1),  float2(1,1),  float2(0,0),  float2(1,0) };
    VertexOut out;
    float2 p = pos[vid];
    out.position = u.mvp * float4(p, 0.0, 1.0);
    float2 t = uv[vid];
    if (u.mirror > 0.5) { t.x = 1.0 - t.x; }
    out.texCoord = t;
    out.local = uv[vid];
    return out;
}

// Sample biplanar YUV (luma R8 + chroma RG8) and convert in-shader — lower
// bandwidth than forcing BGRA out of the camera (ARCHITECTURE.md §3).
fragment float4 dcr_fragment(VertexOut in [[stage_in]],
                             texture2d<float> lumaTex [[texture(0)]],
                             texture2d<float> chromaTex [[texture(1)]],
                             constant QuadUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = lumaTex.sample(s, in.texCoord).r;
    float2 cbcr = chromaTex.sample(s, in.texCoord).rg;
    float3 yuv = float3(y, cbcr) + u.yuvOffset;
    float3 rgb = u.yuvMatrix * yuv;
    float alpha = 1.0;

    if (u.rounded > 0.5) {
        // Rounded-rect SDF in this quad's pixel space.
        float2 px = in.local * u.quadSizePx;
        float2 half = u.quadSizePx * 0.5;
        float2 q = abs(px - half) - (half - u.cornerRadiusPx);
        float dist = length(max(q, 0.0)) - u.cornerRadiusPx;
        alpha = 1.0 - smoothstep(-1.0, 1.0, dist);
    }
    return float4(rgb, alpha);
}
