// ─────────────────────────────────────────────────────────────────────────────
// The first automated test in this repository.
//
// It exists for one change: fpng_encode_card reuses its scratch memory across
// renders instead of allocating it per call. The whole safety argument for that
// is "the bytes are identical to stock fpng", and an argument of that shape is
// worth nothing unless something checks it — so this asserts byte equality on
// every real card in test_out/ plus the synthetic cases those do not cover, and
// decodes each result back to prove the PNG is a PNG and not merely 78 KB that
// compares equal to another 78 KB.
//
// Run: make test
// ─────────────────────────────────────────────────────────────────────────────
#include "../src/vendor/stb_image.h"
#include "../src/vendor/fpng.h"
#include "../src/fpng_card.h"
#include "../src/card_geometry.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int g_failures = 0;
static int g_checks = 0;

static void check(bool ok, const std::string &what)
{
    ++g_checks;
    if (ok)
        return;
    ++g_failures;
    fprintf(stderr, "  FAIL  %s\n", what.c_str());
}

// The property the change rests on.
static void encodes_identically(const std::vector<uint8_t> &rgba, uint32_t w, uint32_t h,
                                const std::string &what)
{
    std::vector<uint8_t> stock, card;
    bool a = fpng::fpng_encode_image_to_memory(rgba.data(), w, h, CH, stock, 0);
    bool b = fpng::fpng_encode_card(rgba.data(), w, h, CH, card);

    check(a && b, what + ": both encoders succeeded");
    check(stock.size() == card.size(),
          what + ": same length (stock " + std::to_string(stock.size()) +
              ", card " + std::to_string(card.size()) + ")");
    if (stock.size() == card.size())
        check(memcmp(stock.data(), card.data(), stock.size()) == 0, what + ": identical bytes");

    // And it is a real PNG carrying the pixels we handed it.
    uint32_t dw = 0, dh = 0, dch = 0;
    std::vector<uint8_t> back;
    int rc = fpng::fpng_decode_memory(card.data(), (uint32_t)card.size(), back, dw, dh, dch, CH);
    check(rc == fpng::FPNG_DECODE_SUCCESS, what + ": decodes");
    check(dw == w && dh == h, what + ": round-trips its dimensions");
    check(back.size() == rgba.size() && memcmp(back.data(), rgba.data(), rgba.size()) == 0,
          what + ": round-trips its pixels");
}

// A deterministic pseudo-random fill. Not for cryptography — for a canvas that
// defeats the RLE, which every card we actually draw does not.
static uint32_t rnd(uint32_t &s) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }

int main(int argc, char **argv)
{
    fpng::fpng_init();
    const std::string dir = argc > 1 ? argv[1] : "test_out";

    // ── the cards the renderer actually produces ─────────────────────────────
    // Real output, not a synthetic approximation: these are the flat grounds,
    // antialiased type and leader dots the encoder meets in production.
    static const char *cards[] = {
        "01_rahul.png", "02_priya.png", "03_amit.png", "04_infosys_ltd.png",
        "05_tcs_limited.png", "06_zeta_pvtltd.png", "07_apex_llc.png",
        "08_blueriver_inc.png", "09_meridian_llp.png", "10_overflow.png",
        "11_superlong_suffix.png", "12_minimal.png"};

    int loaded = 0;
    for (const char *name : cards)
    {
        const std::string path = dir + "/" + name;
        int w = 0, h = 0, n = 0;
        uint8_t *px = stbi_load(path.c_str(), &w, &h, &n, CH);
        if (!px)
        {
            fprintf(stderr, "  SKIP  %s (not found)\n", path.c_str());
            continue;
        }
        ++loaded;
        std::vector<uint8_t> rgba(px, px + (size_t)w * h * CH);
        stbi_image_free(px);
        encodes_identically(rgba, (uint32_t)w, (uint32_t)h, name);
    }
    // A test that cannot find its fixtures looks exactly like a test that
    // passed. Count them.
    check(loaded >= 10, "found the card fixtures (loaded " + std::to_string(loaded) + " of 12)");

    // ── the cases the real cards do not cover ────────────────────────────────
    const size_t N = (size_t)IMG_W * IMG_H * CH;

    {   // Flat: the whole canvas one colour, the RLE's best case.
        std::vector<uint8_t> flat(N);
        for (size_t i = 0; i < N; i += CH) { flat[i] = 0x14; flat[i+1] = 0x12; flat[i+2] = 0x0e; flat[i+3] = 0xff; }
        encodes_identically(flat, IMG_W, IMG_H, "flat ground");
    }
    {   // Noise: the RLE's worst case, and the only thing likely to drive the
        // uncompressed fallback — the one branch no card has ever taken.
        std::vector<uint8_t> noise(N);
        uint32_t s = 0x9E3779B9;
        for (size_t i = 0; i < N; ++i) noise[i] = (uint8_t)(rnd(s) >> 7);
        encodes_identically(noise, IMG_W, IMG_H, "noise");
    }
    {   // A vertical gradient: every scanline differs from the one above it, so
        // the up-filter produces a constant non-zero row rather than zeros.
        std::vector<uint8_t> grad(N);
        for (int y = 0; y < IMG_H; ++y)
            for (int x = 0; x < IMG_W; ++x)
            {
                size_t i = ((size_t)y * IMG_W + x) * CH;
                grad[i] = (uint8_t)(y & 0xff); grad[i+1] = (uint8_t)(x & 0xff);
                grad[i+2] = 0x40; grad[i+3] = 0xff;
            }
        encodes_identically(grad, IMG_W, IMG_H, "gradient");
    }
    {   // One pixel different from flat, in the last row: catches an encoder
        // that quietly stops early.
        std::vector<uint8_t> one(N);
        for (size_t i = 0; i < N; i += CH) { one[i] = 0x14; one[i+1] = 0x12; one[i+2] = 0x0e; one[i+3] = 0xff; }
        one[N - CH] = 0xff;
        encodes_identically(one, IMG_W, IMG_H, "one stray pixel in the last row");
    }

    // ── the geometry guard ───────────────────────────────────────────────────
    // A canvas that is not what this binary was compiled for must fall back to
    // stock fpng and still be correct. Without this the SCALE knob is a way to
    // write past the end of a static buffer.
    {
        const uint32_t w = 64, h = 40;
        std::vector<uint8_t> small((size_t)w * h * CH);
        uint32_t s = 12345;
        for (auto &b : small) b = (uint8_t)(rnd(s) >> 11);
        encodes_identically(small, w, h, "wrong geometry falls back to stock");
    }

    printf("%s  %d checks, %d failed\n", g_failures ? "FAIL" : "ok  ", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
