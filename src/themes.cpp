#include "themes.h"
#include <cstring>
#include <cstdlib>
#include <cerrno>

// ─────────────────────────────────────────────────────────────────────────────
// 12 themes — indices 0-5 dark, 6-11 light
//
// Field order matches struct Theme:
//   id, bg, accent, sub_label, name, sub_name, divider, amt_label, rupee, amount, date
// ─────────────────────────────────────────────────────────────────────────────

const Theme THEMES[THEME_COUNT] = {

    // ── 0: dark-purple ─────────────────────────────────────────────────────
    // Deep near-black with indigo/purple accent.  The original default.
    {
        "dark-purple",
        /* bg        */ {15, 15, 15, 255},
        /* accent    */ {108, 99, 255, 255},  // indigo #6C63FF
        /* sub_label */ {74, 64, 64, 255},    // muted warm grey
        /* name      */ {240, 235, 227, 255}, // warm off-white
        /* sub_name  */ {165, 155, 148, 255}, // mid warm grey - readable suffix
        /* divider   */ {42, 37, 32, 255},
        /* amt_label */ {74, 64, 64, 255},
        /* rupee     */ {108, 99, 255, 255},
        /* amount    */ {240, 235, 227, 255},
        /* date      */ {58, 53, 48, 255},
    },

    // ── 1: dark-emerald ────────────────────────────────────────────────────
    // Near-black with a rich emerald green accent.
    {
        "dark-emerald",
        /* bg        */ {10, 15, 12, 255},
        /* accent    */ {52, 211, 153, 255}, // emerald #34D399
        /* sub_label */ {55, 75, 62, 255},
        /* name      */ {220, 238, 228, 255},
        /* sub_name  */ {130, 165, 145, 255},
        /* divider   */ {25, 45, 33, 255},
        /* amt_label */ {55, 75, 62, 255},
        /* rupee     */ {52, 211, 153, 255},
        /* amount    */ {220, 238, 228, 255},
        /* date      */ {48, 72, 56, 255},
    },

    // ── 2: dark-amber ──────────────────────────────────────────────────────
    // Warm dark with golden amber accent.  Premium feel.
    {
        "dark-amber",
        /* bg        */ {15, 12, 8, 255},
        /* accent    */ {251, 191, 36, 255}, // amber #FBBF24
        /* sub_label */ {85, 68, 45, 255},
        /* name      */ {248, 238, 212, 255},
        /* sub_name  */ {175, 152, 118, 255},
        /* divider   */ {48, 38, 22, 255},
        /* amt_label */ {85, 68, 45, 255},
        /* rupee     */ {251, 191, 36, 255},
        /* amount    */ {248, 238, 212, 255},
        /* date      */ {68, 54, 36, 255},
    },

    // ── 3: dark-ice ────────────────────────────────────────────────────────
    // Cold dark with bright cyan accent.  High-value, tech feel.
    {
        "dark-ice",
        /* bg        */ {8, 12, 18, 255},
        /* accent    */ {103, 232, 249, 255}, // cyan #67E8F9
        /* sub_label */ {52, 70, 88, 255},
        /* name      */ {215, 235, 248, 255},
        /* sub_name  */ {120, 158, 192, 255},
        /* divider   */ {22, 38, 58, 255},
        /* amt_label */ {52, 70, 88, 255},
        /* rupee     */ {103, 232, 249, 255},
        /* amount    */ {215, 235, 248, 255},
        /* date      */ {45, 65, 88, 255},
    },

    // ── 4: dark-rose ───────────────────────────────────────────────────────
    // Warm dark with rose/pink accent.  Creative / luxury.
    {
        "dark-rose",
        /* bg        */ {15, 10, 12, 255},
        /* accent    */ {251, 113, 133, 255}, // rose #FB7185
        /* sub_label */ {85, 58, 65, 255},
        /* name      */ {248, 228, 232, 255},
        /* sub_name  */ {178, 142, 152, 255},
        /* divider   */ {50, 28, 35, 255},
        /* amt_label */ {85, 58, 65, 255},
        /* rupee     */ {251, 113, 133, 255},
        /* amount    */ {248, 228, 232, 255},
        /* date      */ {68, 48, 55, 255},
    },

    // ── 5: dark-slate ──────────────────────────────────────────────────────
    // Cool-toned dark with steel blue accent.  Corporate / confident.
    {
        "dark-slate",
        /* bg        */ {12, 14, 18, 255},
        /* accent    */ {99, 130, 201, 255}, // steel blue #6382C9
        /* sub_label */ {58, 68, 88, 255},
        /* name      */ {222, 230, 248, 255},
        /* sub_name  */ {135, 152, 192, 255},
        /* divider   */ {28, 38, 58, 255},
        /* amt_label */ {58, 68, 88, 255},
        /* rupee     */ {99, 130, 201, 255},
        /* amount    */ {222, 230, 248, 255},
        /* date      */ {48, 60, 88, 255},
    },

    // ── 6: light-ivory ─────────────────────────────────────────────────────
    // Warm cream background with purple accent.  Clean, timeless.
    {
        "light-ivory",
        /* bg        */ {252, 248, 240, 255},
        /* accent    */ {108, 99, 255, 255},
        /* sub_label */ {162, 152, 140, 255},
        /* name      */ {38, 32, 26, 255},
        /* sub_name  */ {110, 102, 92, 255},
        /* divider   */ {208, 200, 188, 255},
        /* amt_label */ {162, 152, 140, 255},
        /* rupee     */ {108, 99, 255, 255},
        /* amount    */ {38, 32, 26, 255},
        /* date      */ {178, 168, 155, 255},
    },

    // ── 7: light-sage ──────────────────────────────────────────────────────
    // Light green-tinted background with sage green accent.
    {
        "light-sage",
        /* bg        */ {244, 250, 244, 255},
        /* accent    */ {34, 150, 100, 255}, // sage #229664
        /* sub_label */ {118, 148, 128, 255},
        /* name      */ {22, 50, 35, 255},
        /* sub_name  */ {88, 125, 105, 255},
        /* divider   */ {188, 218, 198, 255},
        /* amt_label */ {118, 148, 128, 255},
        /* rupee     */ {34, 150, 100, 255},
        /* amount    */ {22, 50, 35, 255},
        /* date      */ {138, 170, 148, 255},
    },

    // ── 8: light-sky ───────────────────────────────────────────────────────
    // Light blue-tinted background with sky blue accent.
    {
        "light-sky",
        /* bg        */ {238, 247, 255, 255},
        /* accent    */ {59, 130, 246, 255}, // blue #3B82F6
        /* sub_label */ {108, 145, 188, 255},
        /* name      */ {18, 42, 82, 255},
        /* sub_name  */ {88, 128, 175, 255},
        /* divider   */ {182, 212, 242, 255},
        /* amt_label */ {108, 145, 188, 255},
        /* rupee     */ {59, 130, 246, 255},
        /* amount    */ {18, 42, 82, 255},
        /* date      */ {128, 168, 208, 255},
    },

    // ── 9: light-peach ─────────────────────────────────────────────────────
    // Warm peach background with burnt orange accent.
    {
        "light-peach",
        /* bg        */ {255, 246, 238, 255},
        /* accent    */ {234, 112, 60, 255}, // burnt orange #EA703C
        /* sub_label */ {178, 145, 122, 255},
        /* name      */ {65, 32, 15, 255},
        /* sub_name  */ {148, 115, 92, 255},
        /* divider   */ {232, 200, 178, 255},
        /* amt_label */ {178, 145, 122, 255},
        /* rupee     */ {234, 112, 60, 255},
        /* amount    */ {65, 32, 15, 255},
        /* date      */ {188, 158, 135, 255},
    },

    // ── 10: light-lavender ─────────────────────────────────────────────────
    // Soft lavender tint with violet accent.
    {
        "light-lavender",
        /* bg        */ {248, 244, 255, 255},
        /* accent    */ {124, 58, 237, 255}, // violet #7C3AED
        /* sub_label */ {155, 138, 188, 255},
        /* name      */ {42, 22, 80, 255},
        /* sub_name  */ {122, 108, 162, 255},
        /* divider   */ {208, 198, 238, 255},
        /* amt_label */ {155, 138, 188, 255},
        /* rupee     */ {124, 58, 237, 255},
        /* amount    */ {42, 22, 80, 255},
        /* date      */ {172, 158, 210, 255},
    },

    // ── 11: light-stone ────────────────────────────────────────────────────
    // Neutral stone background with grey accent.  Understated, professional.
    {
        "light-stone",
        /* bg        */ {248, 246, 242, 255},
        /* accent    */ {120, 113, 108, 255}, // stone #787068
        /* sub_label */ {162, 158, 152, 255},
        /* name      */ {38, 36, 33, 255},
        /* sub_name  */ {118, 114, 108, 255},
        /* divider   */ {208, 204, 198, 255},
        /* amt_label */ {162, 158, 152, 255},
        /* rupee     */ {80, 75, 72, 255},
        /* amount    */ {38, 36, 33, 255},
        /* date      */ {178, 174, 168, 255},
    },
};

// ─────────────────────────────────────────────────────────────────────────────
// Lookup helper
// ─────────────────────────────────────────────────────────────────────────────

const Theme &theme_by_id(const char *id)
{
    if (id && *id)
    {
        for (int i = 0; i < THEME_COUNT; ++i)
        {
            if (std::strcmp(THEMES[i].id, id) == 0)
                return THEMES[i];
        }
    }
    return THEMES[0]; // default: dark-purple
}

// ─────────────────────────────────────────────────────────────────────────────
// Amount-ladder default selector
//
// Thresholds (paise = rupees × 100):
//   < ₹1,000      → dark-purple
//   < ₹10,000     → dark-emerald
//   < ₹50,000     → dark-amber
//   < ₹1,00,000   → dark-ice
//   < ₹5,00,000   → dark-rose
//   ₹5,00,000+    → dark-slate
// ─────────────────────────────────────────────────────────────────────────────

const Theme &theme_for_amount(uint64_t amount_paise)
{
    // Determine base ladder index (0..5) from amount thresholds
    int base = 0;
    if (amount_paise < 100'000ULL)
        base = 0; // dark-purple  < ₹1,000
    else if (amount_paise < 1'000'000ULL)
        base = 1; // dark-emerald < ₹10,000
    else if (amount_paise < 5'000'000ULL)
        base = 2; // dark-amber   < ₹50,000
    else if (amount_paise < 10'000'000ULL)
        base = 3; // dark-ice    < ₹1,00,000
    else if (amount_paise < 50'000'000ULL)
        base = 4; // dark-rose   < ₹5,00,000
    else
        base = 5; // dark-slate  ₹5,00,000+

    // Use the same colour ladder but pick the light variant for even
    // numbers and the dark variant for odd numbers.  The light variants
    // are at indices 6..11 (base + 6).
    bool even = (amount_paise % 2) == 0;
    int idx = base + (even ? 6 : 0);
    return THEMES[idx];
}

// ─────────────────────────────────────────────────────────────────────────────

uint64_t parse_amount_to_paise(const char *s)
{
    if (!s || !*s)
        return 0;
    // strip commas into a local buffer
    char clean[64];
    int ci = 0;
    for (; *s && ci < 62; ++s)
    {
        if (*s != ',')
            clean[ci++] = *s;
    }
    clean[ci] = '\0';
    errno = 0;
    char *end;
    double v = std::strtod(clean, &end);
    if (end == clean || errno != 0 || v < 0.0)
        return 0;
    return static_cast<uint64_t>(v * 100.0 + 0.5);
}
