#pragma once
#include <cstdint>
#include <cstring>
#include <vector>
#include <unordered_map>
#include "vendor/stb_truetype.h"

// ─────────────────────────────────────────────────────────────────────────────
// Glyph rasterization cache
//
// stbtt produces greyscale alpha bitmaps — colour is applied per-pixel at
// blit time — so the same raster serves every colour.  The cache key is
// therefore just (font identity, codepoint, scale).
//
// advance_f is stored as a float (advance * scale) so the caller can add
// fractional letter_spacing before truncating to int, matching the original
// single-render behaviour exactly.
// ─────────────────────────────────────────────────────────────────────────────

struct GlyphBitmap
{
    std::vector<uint8_t> data; // greyscale alpha; empty for whitespace / missing glyph
    int w = 0, h = 0;
    int xoff = 0, yoff = 0;
    float advance_f = 0.f; // advance * scale — add letter_spacing then cast to int
};

struct GlyphKey
{
    const stbtt_fontinfo *font; // pointer identity — one object per loaded font face
    int codepoint;
    float scale;

    bool operator==(const GlyphKey &o) const noexcept
    {
        return font == o.font && codepoint == o.codepoint && scale == o.scale;
    }
};

struct GlyphKeyHash
{
    size_t operator()(const GlyphKey &k) const noexcept;
};

using GlyphCacheMap = std::unordered_map<GlyphKey, GlyphBitmap, GlyphKeyHash>;

// Process-lifetime cache shared across all fonts and render calls.
// Single-threaded — no locking needed (daemon handles one request at a time).
extern GlyphCacheMap g_glyph_cache;

// Return a cached GlyphBitmap, rasterizing on first access.
// Always returns a valid reference; data may be empty for whitespace glyphs.
const GlyphBitmap &glyph_get(const stbtt_fontinfo *font, int codepoint, float scale);
