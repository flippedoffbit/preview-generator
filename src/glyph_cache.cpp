#include "glyph_cache.h"

GlyphCacheMap g_glyph_cache;

size_t GlyphKeyHash::operator()(const GlyphKey &k) const noexcept
{
    // Mix three independent values with coprime multipliers.
    size_t h = reinterpret_cast<size_t>(k.font);
    h ^= static_cast<size_t>(k.codepoint) * 2654435761ULL; // Knuth multiplicative
    uint32_t scale_bits;
    std::memcpy(&scale_bits, &k.scale, sizeof scale_bits); // bit-cast float → u32
    h ^= static_cast<size_t>(scale_bits) * 40503ULL;
    return h;
}

const GlyphBitmap &glyph_get(const stbtt_fontinfo *font, int codepoint, float scale)
{
    GlyphKey key{font, codepoint, scale};

    auto it = g_glyph_cache.find(key);
    if (it != g_glyph_cache.end())
        return it->second;

    GlyphBitmap bm;

    // Advance is always valid, even for whitespace / missing glyphs.
    int advance, lsb;
    stbtt_GetCodepointHMetrics(font, codepoint, &advance, &lsb);
    bm.advance_f = advance * scale;

    // Bitmap — null for whitespace (space, tab, etc.).
    int bw, bh, xoff, yoff;
    uint8_t *raw = stbtt_GetCodepointBitmap(font, 0, scale, codepoint,
                                            &bw, &bh, &xoff, &yoff);
    if (raw)
    {
        bm.data.assign(raw, raw + bw * bh);
        bm.w = bw;
        bm.h = bh;
        bm.xoff = xoff;
        bm.yoff = yoff;
        stbtt_FreeBitmap(raw, nullptr);
    }

    auto [ins, ok] = g_glyph_cache.emplace(key, std::move(bm));
    (void)ok;
    return ins->second;
}
