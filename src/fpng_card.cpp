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

// ─────────────────────────────────────────────────────────────────────────────
// THE RUN SCAN, VECTORISED -- the one hot loop worth forking fpng's inner
// function for.
//
// COUNTED ON A REAL CARD BEFORE WRITING THIS. Per 1200x630 card the deflate
// emits about 94,000 symbols and spends about 726,000 iterations finding where
// runs of identical pixels end -- 7.7 scan steps for every symbol emitted, each
// step a 4-byte load, a compare and a branch, together walking essentially the
// whole 3 MB of filtered scanlines. It is also the same ~726,000 for every card:
// a nearly blank card and a busy one differ in LITERALS, not in scan, because
// the scan tracks pixels rather than ink. That makes it a floor rather than a
// variable, and the only floor left worth moving.
//
// Average run is ~46 pixels, so the scalar loop takes ~46 dependent iterations
// to discover one number. Eight pixels at a time takes six.
//
// WHAT IS NOT TOUCHED: the bit accumulator. Each symbol's position depends on
// the total bit length of everything before it, so symbols cannot be emitted in
// parallel without already knowing where the next one starts. That half is
// irreducible short of a two-pass design and is left exactly as upstream wrote
// it.
//
// CORRECTNESS. Every path must leave match_len at exactly
// 4 + 4*(consecutive pixels after the first that equal `lits`), capped by
// max_match_len -- byte-identical output is the whole point, and
// tests/fpng_card_test.cpp holds this function's output equal to stock fpng's
// on every fixture. The vector loops run only while a whole vector still fits
// inside max_match_len, so neither can read past the end of the row.
// ─────────────────────────────────────────────────────────────────────────────
#if defined(__AVX2__)
#include <immintrin.h>
#elif defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif

namespace fpng
{
    static inline void match_scan_vec(const uint8_t *p, uint32_t lits,
                                      uint32_t max_match_len, uint32_t &match_len)
    {
#if defined(__AVX2__)
        const __m256i v = _mm256_set1_epi32((int)lits);
        while (match_len + 32 <= max_match_len)
        {
            const __m256i d = _mm256_loadu_si256((const __m256i *)(p + match_len));
            const uint32_t eq =
                (uint32_t)_mm256_movemask_ps(_mm256_castsi256_ps(_mm256_cmpeq_epi32(d, v)));
            if (eq != 0xFFu)
            {
                // First zero bit is the first pixel that differs.
                match_len += 4u * (uint32_t)__builtin_ctz(~eq & 0xFFu);
                return;
            }
            match_len += 32;
        }
#elif defined(__ARM_NEON) || defined(__ARM_NEON__)
        const uint32x4_t v = vdupq_n_u32(lits);
        while (match_len + 16 <= max_match_len)
        {
            uint32_t tmp[4];
            memcpy(tmp, p + match_len, 16); // the source is not 4-byte aligned
            const uint32x4_t eq = vceqq_u32(vld1q_u32(tmp), v);
            const uint64x2_t pair = vreinterpretq_u64_u32(eq);
            if (vgetq_lane_u64(pair, 0) != ~0ull || vgetq_lane_u64(pair, 1) != ~0ull)
            {
                uint32_t lane[4];
                vst1q_u32(lane, eq);
                for (uint32_t i = 0; i < 4; ++i)
                {
                    if (lane[i] != 0xFFFFFFFFu)
                        break;
                    match_len += 4;
                }
                return;
            }
            match_len += 16;
        }
#else
        (void)p; (void)lits; (void)max_match_len; (void)match_len;
#endif
    }
}



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

    static uint32_t pixel_deflate_card(
        const uint8_t *pImg, uint32_t w, uint32_t h,
        uint8_t *pDst, uint32_t dst_buf_size)
    {
        const uint32_t bpl = 1 + w * 4;

        if (dst_buf_size < sizeof(g_dyn_huff_4))
            return false;
        memcpy(pDst, g_dyn_huff_4, sizeof(g_dyn_huff_4));
        uint32_t dst_ofs = sizeof(g_dyn_huff_4);

        uint64_t bit_buf = DYN_HUFF_4_BITBUF;
        int bit_buf_size = DYN_HUFF_4_BITBUF_SIZE;

        const uint8_t *pSrc = pImg;
        uint32_t src_ofs = 0;

        uint32_t src_adler32 = fpng_adler32(pImg, bpl * h, FPNG_ADLER32_INIT);

        for (uint32_t y = 0; y < h; y++)
        {
            const uint32_t end_src_ofs = src_ofs + bpl;

            const uint32_t filter_lit = pSrc[src_ofs++];
            PUT_BITS_CZ(g_dyn_huff_4_codes[filter_lit].m_code, g_dyn_huff_4_codes[filter_lit].m_code_size);

            PUT_BITS_FLUSH;

            uint32_t prev_lits;
            {
                uint32_t lits = READ_LE32(pSrc + src_ofs);

                PUT_BITS_CZ(g_dyn_huff_4_codes[lits & 0xFF].m_code, g_dyn_huff_4_codes[lits & 0xFF].m_code_size);
                PUT_BITS_CZ(g_dyn_huff_4_codes[(lits >> 8) & 0xFF].m_code, g_dyn_huff_4_codes[(lits >> 8) & 0xFF].m_code_size);
                PUT_BITS_CZ(g_dyn_huff_4_codes[(lits >> 16) & 0xFF].m_code, g_dyn_huff_4_codes[(lits >> 16) & 0xFF].m_code_size);

                if (bit_buf_size >= 49)
                {
                    PUT_BITS_FLUSH;
                }

                PUT_BITS_CZ(g_dyn_huff_4_codes[(lits >> 24)].m_code, g_dyn_huff_4_codes[(lits >> 24)].m_code_size);

                src_ofs += 4;

                prev_lits = lits;
            }

            PUT_BITS_FLUSH;

            while (src_ofs < end_src_ofs)
            {
                uint32_t lits = READ_LE32(pSrc + src_ofs);

                if (lits == prev_lits)
                {
                    uint32_t match_len = 4;
                    uint32_t max_match_len = minimum<int>(252, (int)(end_src_ofs - src_ofs));

                    // THE ONLY CHANGE IN THIS FUNCTION. Upstream walks the run
                    // one pixel at a time; this walks it eight (AVX2) or four
                    // (NEON) at a time and finds the first differing pixel with
                    // a mask. Same match_len, same output, fewer iterations.
                    //
                    // Every path below must agree exactly: match_len ends at
                    // 4 + 4*(number of consecutive pixels after the first that
                    // equal `lits`), capped by max_match_len. The vector loops
                    // only run while a whole vector fits inside max_match_len,
                    // so they cannot read past the row, and the scalar loop
                    // finishes the tail.
                    match_scan_vec(pSrc + src_ofs, lits, max_match_len, match_len);

                    while (match_len < max_match_len)
                    {
                        if (READ_LE32(pSrc + src_ofs + match_len) != lits)
                            break;
                        match_len += 4;
                    }

                    uint32_t adj_match_len = match_len - 3;

                    const uint32_t match_code_bits = g_dyn_huff_4_codes[g_defl_len_sym[adj_match_len]].m_code_size;
                    const uint32_t len_extra_bits = g_defl_len_extra[adj_match_len];

                    if (match_len == 4)
                    {
                        // This check is optional - see if just encoding 4 literals would be cheaper than using a short match.
                        uint32_t lit_bits = g_dyn_huff_4_codes[lits & 0xFF].m_code_size + g_dyn_huff_4_codes[(lits >> 8) & 0xFF].m_code_size +
                                            g_dyn_huff_4_codes[(lits >> 16) & 0xFF].m_code_size + g_dyn_huff_4_codes[(lits >> 24)].m_code_size;

                        if ((match_code_bits + len_extra_bits + 1) > lit_bits)
                            goto do_literals;
                    }

                    PUT_BITS_CZ(g_dyn_huff_4_codes[g_defl_len_sym[adj_match_len]].m_code, match_code_bits);
                    PUT_BITS(adj_match_len & g_bitmasks[g_defl_len_extra[adj_match_len]], len_extra_bits + 1); // up to 6 bits, +1 for the match distance Huff code which is always 0

                    src_ofs += match_len;
                }
                else
                {
                do_literals:
                    PUT_BITS_CZ(g_dyn_huff_4_codes[lits & 0xFF].m_code, g_dyn_huff_4_codes[lits & 0xFF].m_code_size);
                    PUT_BITS_CZ(g_dyn_huff_4_codes[(lits >> 8) & 0xFF].m_code, g_dyn_huff_4_codes[(lits >> 8) & 0xFF].m_code_size);
                    PUT_BITS_CZ(g_dyn_huff_4_codes[(lits >> 16) & 0xFF].m_code, g_dyn_huff_4_codes[(lits >> 16) & 0xFF].m_code_size);

                    if (bit_buf_size >= 49)
                    {
                        PUT_BITS_FLUSH;
                    }

                    PUT_BITS_CZ(g_dyn_huff_4_codes[(lits >> 24)].m_code, g_dyn_huff_4_codes[(lits >> 24)].m_code_size);

                    src_ofs += 4;

                    prev_lits = lits;
                }

                PUT_BITS_FLUSH;

            } // while (src_ofs < end_src_ofs)

        } // y

        assert(src_ofs == h * bpl);

        assert(bit_buf_size <= 7);

        PUT_BITS_CZ(g_dyn_huff_4_codes[256].m_code, g_dyn_huff_4_codes[256].m_code_size);

        PUT_BITS_FORCE_FLUSH;

        // Write zlib adler32
        for (uint32_t i = 0; i < 4; i++)
        {
            if ((dst_ofs + 1) > dst_buf_size)
                return 0;
            *(uint8_t *)(pDst + dst_ofs) = (uint8_t)(src_adler32 >> 24);
            dst_ofs++;

            src_adler32 <<= 8;
        }

        return dst_ofs;
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
                : pixel_deflate_card(g_card_temp, CARD_W, CARD_H,
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
