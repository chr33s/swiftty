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
    uint underline; // RGBA underline color; 0 uses fg
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
    uint blinkHidden; // text with FlagBlink is in its off phase
};

constant uint FlagColorGlyph = 1u << 0;
constant uint FlagUnderline = 1u << 1;
constant uint FlagDoubleUnderline = 1u << 2;
constant uint FlagStrike = 1u << 3;
constant uint FlagOverline = 1u << 4;
constant uint FlagCursorBar = 1u << 5;
constant uint FlagCursorRight = 1u << 13;
constant uint FlagCursorUnderline = 1u << 6;
constant uint FlagFaint = 1u << 7;
constant uint FlagCursorHollow = 1u << 8;
constant uint FlagCurly = 1u << 9;
constant uint FlagDotted = 1u << 10;
constant uint FlagDashed = 1u << 11;
constant uint FlagBlink = 1u << 12;
constant uint DecorationSlots = 7;

// Decoration patterns, in `VertexOut.colorGlyph` for the decoration pass.
constant uint PatternSolid = 0;
constant uint PatternDouble = 1;
constant uint PatternCurly = 2;
constant uint PatternDotted = 3;
constant uint PatternDashed = 4;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
    uint colorGlyph [[flat]];
    // Decorations: rect height, line thickness, pattern period.
    float3 pattern [[flat]];
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
    out.pattern = float3(0);
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
    bool hidden = size.x == 0 || ((c.flags & FlagBlink) && u.blinkHidden);
    out.position = hidden ? float4(0) : toClip(origin + k * size, u);
    out.texCoord = (float2(c.atlasPos) + k * size) / u.atlasSize;
    out.color = unpack(c.fg);
    if (c.flags & FlagFaint) out.color.a *= 0.5;
    out.colorGlyph = (c.flags & FlagColorGlyph) ? 1 : 0;
    out.pattern = float3(0);
    return out;
}

// Decoration slots per cell: underline, strike, cursor (bar, underline,
// or a hollow block's top edge), the hollow block's other edges, then overline.
vertex VertexOut decoration_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant CellInstance *cells [[buffer(0)]],
                                   constant Uniforms &u [[buffer(1)]]) {
    CellInstance c = cells[iid / DecorationSlots];
    uint slot = iid % DecorationSlots;
    float2 cell = u.origin + float2(c.grid) * u.cellSize;
    float t = u.underlineThickness;
    float4 rect = float4(0); // x, y, w, h
    float4 color = unpack(c.fg);
    uint pattern = PatternSolid;
    float period = 0;
    if (slot == 0) {
        if (c.underline != 0) color = unpack(c.underline);
        if (c.flags & FlagDoubleUnderline) {
            rect = float4(0, u.underlinePosition - t, u.cellSize.x, t * 3);
            pattern = PatternDouble;
        } else if (c.flags & FlagCurly) {
            // One wave per cell, so neighbouring cells join.
            float h = max(t * 4, 4.0);
            rect = float4(0, u.underlinePosition + t / 2 - h / 2, u.cellSize.x, h);
            pattern = PatternCurly;
            period = u.cellSize.x;
        } else if (c.flags & FlagDotted) {
            rect = float4(0, u.underlinePosition, u.cellSize.x, t);
            pattern = PatternDotted;
            period = max(t * 2, 2.0);
        } else if (c.flags & FlagDashed) {
            rect = float4(0, u.underlinePosition, u.cellSize.x, t);
            pattern = PatternDashed;
            period = u.cellSize.x / 2;
        } else if (c.flags & FlagUnderline) {
            rect = float4(0, u.underlinePosition, u.cellSize.x, t);
        }
    } else if (slot == 1) {
        if (c.flags & FlagStrike) rect = float4(0, round(u.cellSize.y * 0.55), u.cellSize.x, t);
    } else if (slot == 6) {
        if (c.flags & FlagOverline) rect = float4(0, 0, u.cellSize.x, t);
    } else {
        color = unpack(u.cursorColor);
        float w = max(2.0, t * 2);
        if (slot == 2) {
            if (c.flags & FlagCursorBar) rect = float4(0, 0, w, u.cellSize.y);
            else if (c.flags & FlagCursorRight) rect = float4(u.cellSize.x - w, 0, w, u.cellSize.y);
            else if (c.flags & FlagCursorUnderline) rect = float4(0, u.cellSize.y - w, u.cellSize.x, w);
            else if (c.flags & FlagCursorHollow) rect = float4(0, 0, u.cellSize.x, w);
        } else if (c.flags & FlagCursorHollow) {
            if (slot == 3) rect = float4(0, u.cellSize.y - w, u.cellSize.x, w);
            else if (slot == 4) rect = float4(0, 0, w, u.cellSize.y);
            else rect = float4(u.cellSize.x - w, 0, w, u.cellSize.y);
        }
    }
    VertexOut out;
    float2 k = corner(vid);
    bool textDecoration = slot < 2 || slot == 6;
    bool hidden = rect.z == 0 || (textDecoration && (c.flags & FlagBlink) && u.blinkHidden);
    out.position = hidden ? float4(0) : toClip(cell + rect.xy + k * rect.zw, u);
    // Row-relative x keeps patterns continuous across cells; y is local.
    out.texCoord = float2(cell.x - u.origin.x + rect.x + k.x * rect.z, k.y * rect.w);
    out.color = color;
    out.colorGlyph = pattern;
    out.pattern = float3(rect.w, t, period);
    return out;
}

fragment float4 decoration_fragment(VertexOut in [[stage_in]]) {
    float x = in.texCoord.x, y = in.texCoord.y;
    float h = in.pattern.x, t = in.pattern.y, period = in.pattern.z;
    float coverage = 1;
    switch (in.colorGlyph) {
    case PatternDouble:
        coverage = (y < t || y >= h - t) ? 1 : 0;
        break;
    case PatternCurly: {
        float amplitude = (h - t) / 2;
        float center = h / 2 + amplitude * sin(x / period * 2 * M_PI_F);
        coverage = clamp(t / 2 + 0.5 - abs(y - center), 0.0, 1.0);
        break;
    }
    case PatternDotted:
        coverage = fmod(x, period) < period / 2 ? 1 : 0;
        break;
    case PatternDashed:
        coverage = fmod(x, period) < period * 0.6 ? 1 : 0;
        break;
    default:
        break;
    }
    float a = in.color.a * coverage;
    return float4(in.color.rgb * a, a);
}

fragment float4 solid_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

fragment float4 glyph_fragment(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float4 texel = atlas.sample(s, in.texCoord);
    if (in.colorGlyph) return texel * in.color.a; // premultiplied color bitmap
    float a = texel.a * in.color.a;
    return float4(in.color.rgb * a, a);
}
