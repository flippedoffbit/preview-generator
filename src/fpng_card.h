#pragma once
#include <cstdint>
#include <vector>

namespace fpng
{
    // Encode ONE card, reusing the same scratch memory on every call.
    //
    // Identical bytes to fpng_encode_image_to_memory(pImage, w, h, chans, out, 0)
    // — that is asserted by tests/fpng_card_test.cpp against real cards, and it
    // is the only reason this exists rather than a tuned re-implementation.
    //
    // If w/h/chans are not the geometry this binary was compiled for it falls
    // back to stock fpng rather than misbehaving, so a SCALE change that only
    // rebuilds half the tree costs speed and never correctness.
    bool fpng_encode_card(const void *pImage, uint32_t w, uint32_t h, uint32_t chans,
                          std::vector<uint8_t> &out);
}
