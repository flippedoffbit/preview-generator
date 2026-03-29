#pragma once
#include <cstdint>

// ─────────────────────────────────────────────────────────────────────────────
// RGBA colour + Theme
// ─────────────────────────────────────────────────────────────────────────────

struct RGBA
{
    uint8_t r, g, b, a;
};

struct Theme
{
    const char *id; // unique identifier, e.g. "dark-purple"
    RGBA bg;        // canvas background
    RGBA accent;    // top accent bar
    RGBA sub_label; // "BILLED TO" / "TOTAL PAYABLE" muted label
    RGBA name;      // primary company name
    RGBA sub_name;  // business suffix (Ltd, LLC, …)
    RGBA divider;   // horizontal rule
    RGBA amt_label; // "TOTAL PAYABLE" label text
    RGBA rupee;     // ₹ symbol
    RGBA amount;    // amount digits
    RGBA date;      // date text (bottom-right)
};

static constexpr int THEME_COUNT = 12;
extern const Theme THEMES[THEME_COUNT]; // defined in themes.cpp

// Look up a theme by its id string.
// Returns THEMES[0] if id is null, empty, or not found.
const Theme &theme_by_id(const char *id);

// Choose a theme automatically based on invoice amount in paise (amount × 100).
// Cycles through the six dark themes across typical invoice value ranges.
const Theme &theme_for_amount(uint64_t amount_paise);

// Parse an amount string like "1,23,456.00" or "50000" to paise.
// Returns 0 on failure.
uint64_t parse_amount_to_paise(const char *s);
