// ─────────────────────────────────────────────────────────────────────────────
// Buffer reuse for the PNG encoder.
//
// WHAT THIS IS FOR, MEASURED ON THE DEPLOY HOST BEFORE IT WAS WRITTEN.
// fpng_encode_image_to_memory allocates two ~3 MB scratch buffers per call: a
// filtered-scanline buffer it owns, and the caller's output vector, which it
// resizes to the worst case (the whole raw image) before shrinking it back to
// the ~78 KB the card actually compresses to. On the live box — static musl,
// so both are over the mmap threshold — that is 1479 minor page faults PER
// CARD, counted with getrusage: mmap, touch 739 pages, munmap, twice.
//
// Measured there, 1200x630 RGBA, interleaved A/B in one process so the
// neighbours on that shared box hit both paths equally:
//
//     stock fpng                     5562 us
//     this, buffers process-owned    1080 us      5.15x, byte-identical
//
// The same change is worth 1.02x on a Mac, because macOS's allocator caches
// the block instead of returning it to the kernel. Benchmarking this locally
// would have concluded there was nothing here.
//
// NOTE WHAT IS *NOT* HERE. Specialising the scan loops on the compile-time
// width as well — constant bpl, no filter tail, no per-flush bounds test — was
// written and measured at 17-45 us, about 3% of the encode. It is not worth
// carrying a fork of fpng's inner loops for, so this file leaves every hot
// loop exactly as upstream wrote it and changes only where the memory comes
// from.
//
// WHY IT INCLUDES THE .cpp. Everything the encode needs — apply_filter,
// pixel_deflate_dyn_4_rle_one_pass, write_raw_block — is `static` inside
// fpng.cpp and unreachable from another translation unit. Including it keeps
// src/vendor/fpng.cpp byte-for-byte upstream, so re-merging a new release is a
// straight file copy rather than a diff against our edits. The Makefile
// compiles THIS file in place of the vendored one; compiling both would be two
// definitions of every fpng symbol.
//
// THREAD SAFETY: none, deliberately. The daemon is one process serving
// connections sequentially with one render in flight (see run_daemon), and the
// canvas it encodes is already a single reused member for the same reason. If
// that ever changes, these become thread_local and the cost is one 3 MB
// allocation per thread rather than per request.
// ─────────────────────────────────────────────────────────────────────────────
#include "vendor/fpng.cpp"

#include "card_geometry.h"
#include "fpng_card.h"

#include <cstring>

namespace fpng
{
    namespace
    {
        constexpr uint32_t CARD_W = (uint32_t)IMG_W;
        constexpr uint32_t CARD_H = (uint32_t)IMG_H;
        constexpr uint32_t CARD_CH = (uint32_t)CH;

        constexpr uint32_t CARD_BPL = CARD_W * CARD_CH;
        // fpng's own sizing: one filter byte per scanline, plus the 7 bytes of
        // slack its 64-bit stores read past the end.
        constexpr uint32_t CARD_TEMP_BYTES = (CARD_BPL + 1) * CARD_H + 7;
        constexpr uint32_t CARD_PNG_HEADER = 58;

        // Worst case output: the uncompressed fallback, which stores the
        // filtered image whole in 65535-byte deflate blocks with a 5-byte
        // header each, plus the 2-byte zlib header, the 58-byte PNG header and
        // the 16-byte IDAT-CRC-and-IEND tail. Rounded up generously — this is
        // .bss, not a per-request cost, and being tight here buys nothing.
        constexpr uint32_t CARD_OUT_BYTES =
            CARD_PNG_HEADER + 2 + CARD_TEMP_BYTES +
            ((CARD_TEMP_BYTES / 65535) + 1) * 5 + 16 + 64;

        // The reuse. Allocated once by the loader, never freed, never zeroed
        // between renders: every byte either gets written by the filter pass or
        // is never read.
        uint8_t g_card_temp[CARD_TEMP_BYTES];
        uint8_t g_card_out[CARD_OUT_BYTES];
    }

    bool fpng_encode_card(const void *pImage, uint32_t w, uint32_t h, uint32_t chans,
                          std::vector<uint8_t> &out)
    {
        // Be wrong in the safe direction: an unexpected geometry is a slow
        // card, not a buffer overrun.
        if (w != CARD_W || h != CARD_H || chans != CARD_CH)
            return fpng_encode_image_to_memory(pImage, w, h, chans, out, 0);

        const uint8_t *pImg = (const uint8_t *)pImage;

        uint32_t temp_ofs = 0;
        for (uint32_t y = 0; y < CARD_H; ++y)
        {
            apply_filter(y ? 2 : 0, (int)CARD_W, (int)CARD_H, CARD_CH, CARD_BPL,
                         pImg + (size_t)y * CARD_BPL,
                         y ? pImg + (size_t)(y - 1) * CARD_BPL : nullptr,
                         g_card_temp + temp_ofs);
            temp_ofs += 1 + CARD_BPL;
        }

        uint32_t zlib_size =
            (CARD_CH == 3)
                ? pixel_deflate_dyn_3_rle_one_pass(g_card_temp, CARD_W, CARD_H,
                                                   g_card_out + CARD_PNG_HEADER,
                                                   CARD_OUT_BYTES - CARD_PNG_HEADER)
                : pixel_deflate_dyn_4_rle_one_pass(g_card_temp, CARD_W, CARD_H,
                                                   g_card_out + CARD_PNG_HEADER,
                                                   CARD_OUT_BYTES - CARD_PNG_HEADER);

        if (!zlib_size)
        {
            // Dynamic block failed to compress — store it, filter 0. Unreached
            // by any card we draw (a flat ground with text always compresses),
            // which is exactly why it is kept identical to upstream's rather
            // than tidied.
            temp_ofs = 0;
            for (uint32_t y = 0; y < CARD_H; ++y)
            {
                apply_filter(0, (int)CARD_W, (int)CARD_H, CARD_CH, CARD_BPL,
                             pImg + (size_t)y * CARD_BPL, nullptr, g_card_temp + temp_ofs);
                temp_ofs += 1 + CARD_BPL;
            }
            zlib_size = write_raw_block(g_card_temp, temp_ofs,
                                        g_card_out + CARD_PNG_HEADER,
                                        CARD_OUT_BYTES - CARD_PNG_HEADER);
            if (!zlib_size)
                return false;
        }

        const uint32_t idat_len = zlib_size;
        {
            static const uint8_t s_color_type[] = {0x00, 0x00, 0x04, 0x02, 0x06};
            uint8_t pnghdr[CARD_PNG_HEADER] = {
                0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,                     // PNG sig
                0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R',                         // IHDR len, type
                0, 0, (uint8_t)(CARD_W >> 8), (uint8_t)CARD_W,                      // width
                0, 0, (uint8_t)(CARD_H >> 8), (uint8_t)CARD_H,                      // height
                8,                                                                  // bit depth
                s_color_type[CARD_CH],                                              // colour type
                0, 0, 0,                                                            // compression, filter, interlace
                0, 0, 0, 0,                                                         // IHDR crc32
                0, 0, 0, 5, 'f', 'd', 'E', 'C', 82, 36, 147, 227,
                FPNG_FDEC_VERSION, 0xE5, 0xAB, 0x62, 0x99,                          // fpng's private fdEC chunk
                (uint8_t)(idat_len >> 24), (uint8_t)(idat_len >> 16),
                (uint8_t)(idat_len >> 8), (uint8_t)idat_len, 'I', 'D', 'A', 'T'};

            uint32_t c = (uint32_t)fpng_crc32(pnghdr + 12, 17, FPNG_CRC32_INIT);
            for (int i = 0; i < 4; ++i, c <<= 8)
                pnghdr[29 + i] = (uint8_t)(c >> 24);

            memcpy(g_card_out, pnghdr, CARD_PNG_HEADER);
        }

        uint32_t total = CARD_PNG_HEADER + zlib_size;
        // IDAT's CRC32 (filled in below) followed by a zero-length IEND.
        memcpy(g_card_out + total, "\0\0\0\0\0\0\0\0\x49\x45\x4e\x44\xae\x42\x60\x82", 16);
        total += 16;

        uint32_t c = (uint32_t)fpng_crc32(g_card_out + CARD_PNG_HEADER - 4, idat_len + 4,
                                          FPNG_CRC32_INIT);
        for (int i = 0; i < 4; ++i, c <<= 8)
            g_card_out[total - 16 + i] = (uint8_t)(c >> 24);

        out.assign(g_card_out, g_card_out + total);
        return true;
    }
}
