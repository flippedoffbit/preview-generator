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

    // A seam for tests only. The card encoder computes the zlib checksum with
    // its own AVX2 routine where the target has it, and a wrong checksum is not
    // a crash -- it is a PNG that some decoders accept and some reject, which
    // would surface as one messaging app showing a broken image and the rest
    // showing the card. So it is held equal to fpng's own for every length from
    // 0 to 8192, and that check has to be able to call it.
    uint32_t fpng_card_adler32(const uint8_t *p, size_t len);
}
