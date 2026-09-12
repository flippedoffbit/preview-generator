#pragma once
// ─────────────────────────────────────────────────────────────────────────────
// The card's pixel geometry — the ONE definition of it.
//
// This was computed inside main.cpp until the PNG encoder started depending on
// it too. Two files each deriving the size from BILLPREVIEW_SCALE is two files
// that can disagree after a `make SCALE=0.5` that only rebuilds one of them,
// and the disagreement would not be a wrong-looking card: the encoder writes
// (w*ch+1)*h bytes into a buffer sized from its own idea of w and h.
//
// So both include this, and the encoder ALSO checks at run time that the
// canvas it was handed is the one it was compiled for (see fpng_card.h).
// ─────────────────────────────────────────────────────────────────────────────

// The design is authored at 1200x630 (the OG-card reference — the universal
// minimum for WhatsApp/iMessage/Google Messages). BILLPREVIEW_SCALE rescales
// the WHOLE layout — canvas, positions, font sizes — at build time, trading
// softness for render cost. The 1.91:1 ratio is preserved, so previews still
// crop correctly.
//
//   -DBILLPREVIEW_SCALE=1.0    -> 1200x630  (default, crispest)
//   -DBILLPREVIEW_SCALE=0.667  ->  800x420
//   -DBILLPREVIEW_SCALE=0.5    ->  600x315  (~1/4 the pixels, softer)
#ifndef BILLPREVIEW_SCALE
#define BILLPREVIEW_SCALE 1.0f
#endif

static constexpr float SCALE = BILLPREVIEW_SCALE;
static constexpr int IMG_W = (int)(1200 * SCALE + 0.5f);
static constexpr int IMG_H = (int)(630 * SCALE + 0.5f);
static constexpr int CH = 4; // RGBA
