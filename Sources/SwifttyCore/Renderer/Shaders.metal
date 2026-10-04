#include <metal_stdlib>
using namespace metal;

// Must match `CellInstance` in MetalRenderer.swift.
struct CellInstance {
    ushort2 grid;
    ushort2 atlasPos;
    ushort2 atlasSize;
    short2 offset;
    uint fg;
    uint bg;
    uint flags;
};

// Must match `Uniforms` in MetalRenderer.swift.
struct Uniforms {
    float2 cellSize;
    float2 viewportSize;
    float2 atlasSize;
    float2 origin;
    float underlinePosition;
    float underlineThickness;
    uint cursorColor;
    uint pad;
};

constant uint FlagColorGlyph = 1u << 0;
constant uint FlagUnderline = 1u << 1;
constant uint FlagDoubleUnderline = 1u << 2;
constant uint FlagStrike = 1u << 3;
constant uint FlagOverline = 1u << 4;
constant uint FlagCursorBar = 1u << 5;
constant uint FlagCursorUnderline = 1u << 6;
constant uint FlagFaint = 1u << 7;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
    uint colorGlyph [[flat]];
};

static float4 unpack(uint rgba) {
    return float4(float((rgba >> 24) & 0xFF), float((rgba >> 16) & 0xFF),
                  float((rgba >> 8) & 0xFF), float(rgba & 0xFF)) / 255.0;
}

static float4 toClip(float2 pixel, constant Uniforms &u) {
    float2 ndc = pixel / u.viewportSize * 2.0 - 1.0;
    return float4(ndc.x, -ndc.y, 0.0, 1.0);
}

static float2 corner(uint vid) {
    return float2(float(vid & 1u), float(vid >> 1));
}

vertex VertexOut background_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant CellInstance *cells [[buffer(0)]],
                                   constant Uniforms &u [[buffer(1)]]) {
    CellInstance c = cells[iid];
    float2 origin = u.origin + float2(c.grid) * u.cellSize;
    VertexOut out;
    out.position = toClip(origin + corner(vid) * u.cellSize, u);
    out.texCoord = float2(0);
    out.color = unpack(c.bg);
    out.colorGlyph = 0;
    return out;
}

vertex VertexOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant CellInstance *cells [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    CellInstance c = cells[iid];
    VertexOut out;
    float2 size = float2(c.atlasSize);
    float2 origin = u.origin + float2(c.grid) * u.cellSize + float2(c.offset);
    float2 k = corner(vid);
    out.position = size.x == 0 ? float4(0) : toClip(origin + k * size, u);
    out.texCoord = (float2(c.atlasPos) + k * size) / u.atlasSize;
    out.color = unpack(c.fg);
    if (c.flags & FlagFaint) out.color.a *= 0.5;
    out.colorGlyph = (c.flags & FlagColorGlyph) ? 1 : 0;
    return out;
}

// Three decoration slots per cell: underline, strike/overline, cursor.
vertex VertexOut decoration_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant CellInstance *cells [[buffer(0)]],
                                   constant Uniforms &u [[buffer(1)]]) {
    CellInstance c = cells[iid / 3];
    uint slot = iid % 3;
    float2 cell = u.origin + float2(c.grid) * u.cellSize;
    float t = u.underlineThickness;
    float4 rect = float4(0); // x, y, w, h
    float4 color = unpack(c.fg);
    if (slot == 0) {
        if (c.flags & FlagDoubleUnderline) rect = float4(0, u.underlinePosition - t, u.cellSize.x, t * 3);
        else if (c.flags & FlagUnderline) rect = float4(0, u.underlinePosition, u.cellSize.x, t);
    } else if (slot == 1) {
        if (c.flags & FlagStrike) rect = float4(0, round(u.cellSize.y * 0.55), u.cellSize.x, t);
        else if (c.flags & FlagOverline) rect = float4(0, 0, u.cellSize.x, t);
    } else {
        color = unpack(u.cursorColor);
        if (c.flags & FlagCursorBar) rect = float4(0, 0, max(2.0, t * 2), u.cellSize.y);
        else if (c.flags & FlagCursorUnderline) rect = float4(0, u.cellSize.y - max(2.0, t * 2), u.cellSize.x, max(2.0, t * 2));
    }
    VertexOut out;
    out.position = rect.z == 0 ? float4(0) : toClip(cell + rect.xy + corner(vid) * rect.zw, u);
    out.texCoord = float2(0);
    out.color = color;
    out.colorGlyph = 0;
    return out;
}

fragment float4 solid_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

fragment float4 glyph_fragment(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float4 texel = atlas.sample(s, in.texCoord);
    if (in.colorGlyph) return texel; // premultiplied color bitmap
    float a = texel.a * in.color.a;
    return float4(in.color.rgb * a, a);
}
