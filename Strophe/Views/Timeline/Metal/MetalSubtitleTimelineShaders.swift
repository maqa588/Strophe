extension MetalSubtitleTimelineRenderer {
static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct GPUPrimitive {
    float4 rect;
    float4 fillColor;
    float4 strokeColor;
    float4 auxiliaryColor;
    float4 parameters;
};

struct PrimitiveVertexOut {
    float4 position [[position]];
    float2 local;
    float2 size;
    float4 fillColor [[flat]];
    float4 strokeColor [[flat]];
    float4 auxiliaryColor [[flat]];
    float4 parameters [[flat]];
};

float2 timelineCorner(uint vertexID) {
    constexpr float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    return corners[vertexID];
}

vertex PrimitiveVertexOut timelinePrimitiveVertex(
    const device GPUPrimitive *instances [[buffer(0)]],
    constant float2 &viewportSize [[buffer(1)]],
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]]
) {
    GPUPrimitive primitive = instances[instanceID];
    float2 corner = timelineCorner(vertexID);
    float2 pixel = primitive.rect.xy + corner * primitive.rect.zw;

    PrimitiveVertexOut out;
    out.position = float4(
        pixel.x / viewportSize.x * 2.0 - 1.0,
        1.0 - pixel.y / viewportSize.y * 2.0,
        0,
        1
    );
    out.local = corner * primitive.rect.zw;
    out.size = primitive.rect.zw;
    out.fillColor = primitive.fillColor;
    out.strokeColor = primitive.strokeColor;
    out.auxiliaryColor = primitive.auxiliaryColor;
    out.parameters = primitive.parameters;
    return out;
}

float roundedBoxDistance(float2 local, float2 size, float radius) {
    float2 centered = local - size * 0.5;
    float2 q = abs(centered) - (size * 0.5 - radius);
    return length(max(q, float2(0))) + min(max(q.x, q.y), 0.0) - radius;
}

fragment float4 timelinePrimitiveFragment(PrimitiveVertexOut in [[stage_in]]) {
    float radius = min(in.parameters.x, min(in.size.x, in.size.y) * 0.5);
    float strokeWidth = in.parameters.y;
    int mode = int(round(in.parameters.z));
    int flags = int(round(in.parameters.w));

    float distance = roundedBoxDistance(in.local, in.size, radius);
    float aa = max(fwidth(distance), 0.65);
    float coverage = 1.0 - smoothstep(-aa, aa, distance);
    float border = coverage * (1.0 - smoothstep(strokeWidth - aa, strokeWidth + aa, -distance));

    if (mode == 1) {
        float stripePhase = fmod(in.local.x - in.local.y + 1024.0, 8.0);
        float stripe = (1.0 - smoothstep(1.2, 2.0, stripePhase)) * coverage;
        float4 color = mix(in.fillColor, in.auxiliaryColor, stripe * in.auxiliaryColor.a);
        color = mix(color, in.strokeColor, border);
        color.a *= coverage;
        return color;
    }

    if (mode == 2) {
        float dash = step(fmod(in.local.x + in.local.y, 8.0), 4.0);
        float4 color = mix(in.fillColor, in.strokeColor, border * dash);
        color.a *= coverage;
        return color;
    }


    if (mode == 3) {
        float separator = smoothstep(in.size.y - 1.5, in.size.y - 0.5, in.local.y);
        return mix(in.fillColor, in.strokeColor, separator);
    }

    if (mode == 4) {
        float shadowCoverage = 1.0 - smoothstep(-aa * 2.2, aa * 2.2, distance);
        float4 shadow = in.fillColor;
        shadow.a *= shadowCoverage;
        return shadow;
    }

    if ((flags & 2) != 0) {
        float dash = step(fmod(in.local.x + in.local.y, 7.0), 4.0);
        border *= dash;
    }

    float4 color = mix(in.fillColor, in.strokeColor, border);

    if ((flags & 1) != 0 && in.size.x >= 24.0) {
        float markerDistance = length(in.local - float2(10.5, in.size.y * 0.5)) - 2.5;
        float marker = 1.0 - smoothstep(-aa, aa, markerDistance);
        color = mix(color, in.auxiliaryColor, marker);
    }

    if ((flags & 2) != 0 && in.size.x >= 28.0) {
        float2 lockLocal = in.local - float2(in.size.x - 11.0, in.size.y * 0.5);
        float body = step(abs(lockLocal.x), 3.5) * step(abs(lockLocal.y - 1.5), 3.0);
        float shackleOuter = 1.0 - smoothstep(0.7, 1.4, abs(length(float2(lockLocal.x, lockLocal.y + 2.0)) - 3.0));
        float shackle = shackleOuter * step(lockLocal.y, 0.0);
        float lockMask = saturate(body + shackle);
        color = mix(color, in.strokeColor, lockMask);
    }

    if ((flags & 4) != 0 && in.size.x >= 8.0) {
        float handleWidth = min(10.0, max(5.0, in.size.x * 0.22));
        float leftHandle = 1.0 - smoothstep(handleWidth - aa, handleWidth + aa, in.local.x);
        float rightHandle = smoothstep(in.size.x - handleWidth - aa, in.size.x - handleWidth + aa, in.local.x);
        float verticalInset = step(1.0, in.local.y) * step(in.local.y, in.size.y - 1.0);
        float handleMask = saturate(leftHandle + rightHandle) * verticalInset * coverage;
        color = mix(color, float4(1.0, 0.62, 0.0, 1.0), handleMask);
    }

    color.a *= coverage;
    return color;
}

struct GPUText {
    float4 rect;
    float4 uvRect;
    float4 clipRect;
    float4 color;
};

struct TextVertexOut {
    float4 position [[position]];
    float2 uv;
    float2 pixelPosition;
    float4 clipRect [[flat]];
    float4 color [[flat]];
};

vertex TextVertexOut timelineTextVertex(
    const device GPUText *instances [[buffer(0)]],
    constant float2 &viewportSize [[buffer(1)]],
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]]
) {
    GPUText text = instances[instanceID];
    float2 corner = timelineCorner(vertexID);
    float2 pixel = text.rect.xy + corner * text.rect.zw;

    TextVertexOut out;
    out.position = float4(
        pixel.x / viewportSize.x * 2.0 - 1.0,
        1.0 - pixel.y / viewportSize.y * 2.0,
        0,
        1
    );
    out.uv = float2(
        mix(text.uvRect.x, text.uvRect.z, corner.x),
        mix(text.uvRect.y, text.uvRect.w, corner.y)
    );
    out.pixelPosition = pixel;
    out.clipRect = text.clipRect;
    out.color = text.color;
    return out;
}

fragment float4 timelineTextFragment(
    TextVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    if (in.pixelPosition.x < in.clipRect.x ||
        in.pixelPosition.y < in.clipRect.y ||
        in.pixelPosition.x > in.clipRect.x + in.clipRect.z ||
        in.pixelPosition.y > in.clipRect.y + in.clipRect.w) {
        discard_fragment();
    }
    constexpr sampler atlasSampler(address::clamp_to_edge, filter::linear);
    float alpha = atlas.sample(atlasSampler, in.uv).r;
    return float4(in.color.rgb, in.color.a * alpha);
}
"""
}
