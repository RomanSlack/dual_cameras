#include <metal_stdlib>
using namespace metal;

// Vertex passthrough for a textured quad. Position is in NDC; the inset MVP and
// mirror are baked into the texCoords on the CPU side.
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 local; // 0..1 within this quad, for the rounded-corner SDF
};

// Field order MUST match QuadUniforms in MetalCompositor.swift exactly
// (descending alignment: 16 -> 8 -> 4). The Swift struct is memcpy'd in.
struct QuadUniforms {
    float4x4  mvp;            // places the quad (full-frame or inset) in NDC
    float3x3  yuvMatrix;      // BT.709 limited-range YCbCr -> RGB
    float3    yuvOffset;
    float2x2  texXform;       // rotate-upright + aspect-cover (source space)
    float2    quadSizePx;
    float     mirror;         // 1.0 -> flip x (front selfie)
    float     rounded;        // 1.0 -> apply rounded-corner SDF
    float     cornerRadiusPx;
    float     _pad;
};

vertex VertexOut dcr_vertex(uint vid [[vertex_id]],
                            constant QuadUniforms& u [[buffer(0)]]) {
    // Unit quad.
    float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 uv[4]  = { float2(0,1),  float2(1,1),  float2(0,0),  float2(1,0) };
    VertexOut out;
    float2 p = pos[vid];
    out.position = u.mvp * float4(p, 0.0, 1.0);
    // Center the texcoord, mirror (selfie), then rotate-upright + cover-crop via
    // texXform, then un-center — matches the Android GLSL VERTEX order so the
    // recorded file and preview are bit-identical (IOS_HANDOFF §2).
    float2 a = uv[vid] - 0.5;
    if (u.mirror > 0.5) { a.x = -a.x; }
    out.texCoord = u.texXform * a + 0.5;
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
        float2 halfSz = u.quadSizePx * 0.5;
        float2 q = abs(px - halfSz) - (halfSz - u.cornerRadiusPx);
        float dist = length(max(q, 0.0)) - u.cornerRadiusPx;
        alpha = 1.0 - smoothstep(-1.0, 1.0, dist);
    }
    return float4(rgb, alpha);
}
