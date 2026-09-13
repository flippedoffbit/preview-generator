# preview-generator (billpreview) — the link-preview card renderer

Reference for engineers who have to change this next month. Part A is the
renderer itself (this repo, `github.com/flippedoffbit/preview-generator`). Part B
is the deployed daemon and its operations — the half documented in
`billpreview/README.md` in the monorepo, which holds **no source**, only ops
notes. Part C records where the existing prose is stale.

Everything below was derived from `src/`, the `Makefile`, `deploy/`, and the
trunk call sites that build the URL.

---

# Part A — the renderer

## A1. What it is for, and its trust boundary

billpreview draws the **Open Graph card**: the 1200×630 PNG that WhatsApp,
iMessage, Slack and Google Messages show when somebody forwards a shared invoice
or booklet link. It is a pure function of the query string — no database, no
network, no filesystem reads at runtime.

```
scraper ──GET https://taxifo.com/preview.png?company=…&amount=… ──▶ nginx
                                                                     │ fastcgi_pass
                                                                     ▼
                                                              billpreview (UDS)
```

**trunk is deliberately NOT in the image path.** trunk emits the `og:image` URL
and nothing more (`trunk/src/http/api/bill_render_routes.go:740`), because it is
the only thing that knows the bill; nginx `fastcgi_pass`es the card request
straight to the daemon. The route that used to put trunk in the path,
`/bills/preview/{uuid}`, was **deleted on 2026-09-11** — it spoke the legacy
tab-delimited protocol at a FastCGI binary, so it could never have worked, and no
client ever called it.

The consequence for the boundary is blunt: **this is a public, unauthenticated,
uncredentialed renderer that draws whatever the query string says.** It knows
nothing about firms, bills or tenancy. That is what makes it safe to point the
whole fleet at one host (Part B), and it is also why the labels are compiled in
rather than settable — see A4.

It is memory-unsafe by language: untrusted company names go into a C++ font
shaper (`stb_truetype`). The defences are therefore *prevention* (a total parse)
plus the systemd sandbox, not a crash-containment trick — see A7.

## A2. The protocol contract

Three protocol backends compile from one source, selected at build time
(`src/main.cpp:1551`):

| build flag | protocol | how nginx reaches it |
|---|---|---|
| *(none)* | legacy tab-delimited UDS | n/a — a bespoke client |
| `-DPROTO_HTTP` | bare HTTP/1.0 over UDS | `proxy_pass http://unix:…` |
| **`-DPROTO_FCGI`** | **FastCGI over UDS** | **`fastcgi_pass unix:…` — this is what is deployed** |

**The deployed binary speaks FastCGI, and feeding it the tab-delimited protocol
fails SILENTLY.** `handle_client_fcgi` reads the first eight bytes as a record
header (`src/main.cpp:1336`), finds a nonsense content length, and returns
without writing anything. The caller sees a clean EOF: no error, no log line on
either side, indistinguishable from the daemon being down. trunk once carried a
tab-protocol client and it never worked. The only thing that records which
artifact is which is the **suffix on the filename** — `…-fcgi`, `…-http`, or
neither.

### FastCGI request

Fields arrive as `QUERY_STRING` (from `FCGI_PARAMS`, `src/main.cpp:1297`), as an
`application/x-www-form-urlencoded` **request body** (`FCGI_STDIN`), or both.
**The body is parsed second and therefore wins** (`src/main.cpp:1380`): posting a
name is a more deliberate statement than a URL that may have been assembled by
something else.

- Body cap **8 KiB** (`src/main.cpp:1367`), and the excess is **dropped rather
  than the connection** — a handler that stops reading mid-stream desyncs the
  FastCGI conversation and nginx reports a bare 502 with no explanation. 8 KiB is
  two orders of magnitude above the ~200 bytes six bounded fields can occupy.
- **There is deliberately no JSON parser.** A hand-rolled one is the last thing a
  daemon rendering untrusted input on a public URL needs; a POSTed JSON document
  names none of the keys and gets a 400.
- Everything else — path, headers, method — is ignored.

### FastCGI response

`Content-Type: image/png` + `Content-Length`, then the PNG chunked into
65535-byte records, then the empty STDOUT record and `END_REQUEST`
(`src/main.cpp:1417`).

**Empty `company` is a real 400**, not silence (`src/main.cpp:1385`). It used to
`return`, dropping the connection mid-conversation; nginx turns that into a 502
and a scraper renders it as a broken image. trunk holds the better half of the
same fix — it omits the `og:image` tag entirely when it has no name
(`bill_render_routes.go:806`), because a clean title-and-description unfurl beats
a tag pointing somewhere dead.

There is **no `Cache-Control` and no `ETag`** on the response; caching is
whatever nginx and the scrapers decide.

## A3. Inputs, and the caps that are the defence

Keys parsed by `parse_qs` (`src/main.cpp:1196`) — a closed list; anything else is
ignored:

| key | meaning | bound |
|---|---|---|
| `company` | the name on the card | 128 bytes |
| `amount` | the figure, **already formatted by the caller** | 20 bytes |
| `date` | ISO-ish; reformatted by the daemon | 24 bytes |
| `theme` | explicit palette id; unknown ⇒ `THEMES[0]` | — |
| `kind` | `invoice` / `booklet` / `booklet-mixed`; unknown ⇒ `invoice` | — |
| `count` | invoices in the set | digits only, ≤4 chars |
| `more` | rows that did not fit | digits only, ≤4 chars |
| `morea` | what those elided rows come to | 20 bytes |
| `r1`–`r3` | contents-row labels | 64 bytes each |
| `a1`–`a3` | contents-row amounts | 20 bytes each |

`bound_inputs`/`sanitize_field` (`src/main.cpp:1045`, `:1068`) truncate to the
byte cap and strip C0 controls and DEL. Truncation, not rejection — a long name
still renders, ellipsised. A multibyte sequence cut by the byte cap is harmless:
`next_utf8` yields one U+FFFD at the boundary and never over-reads.

**Every cap lives in `build_card` (`src/main.cpp:1118`) rather than at the call
sites, because the caps ARE the defence** — a limit only one of three protocol
backends applies is not a limit. The same reasoning put `CardFields`
(`src/main.cpp:1102`) and `parse_qs` outside the `#if` blocks: they used to be
duplicated per backend, which is how a key added for one silently did nothing in
the others.

`parse_count` (`src/main.cpp:1083`) refuses anything but ≤4 digits *before*
parsing: `atoi` on a hostile string is unbounded work for us and free for the
caller, and a booklet of more than 9999 invoices is not a booklet. Anything
else returns 0, and the count is then dropped from the label rather than a guess
printed beside a real figure.

The name cap of 128 bytes is grounded in what the card can **physically render**
(`src/main.cpp:1057`): the name area auto-fits down to `NAME_SZ_MIN` and holds
~40–45 glyphs at that size, so the visible cut is always the ellipsis and never
the hard cap.

### Money, and who computes the grouping

**The daemon does no number formatting.** `amount` arrives as a finished string —
trunk formats it with `templates.FormatINRPlain`
(`trunk/src/http/api/bill_render_routes.go:780`), which computes Indian
lakh/crore grouping. That is the platform rule: **Indian grouping is computed,
never asked of a locale or a format pattern**, because a locale offers exactly
one grouping size and `₹1,18,000` needs two.

`amount` also carries **no currency symbol**: the daemon draws `₹` itself from
Inter at 70 % of the digit size (`src/main.cpp:934`). Passing one renders it
twice.

The one place the daemon touches the number is `parse_amount_to_paise`
(`src/themes.cpp:264`), which strips commas and `strtod`s — a **double**, and
acceptable only because its sole consumer is the theme ladder. Nothing drawn is
derived from it. Do not reuse it for anything that reaches the canvas.

## A4. Card kinds — a closed vocabulary, with the words held here

`enum class CardKind { Invoice, Booklet, BookletMixed }` (`src/main.cpp:391`),
resolved by `kind_by_id` (`:398`).

| `kind=` | above the name | above the figure |
|---|---|---|
| absent / `invoice` | `BILLED TO` | `TOTAL PAYABLE` |
| `booklet` | `N INVOICES BILLED TO` | `TOTAL BILLED` |
| `booklet-mixed` | `N INVOICES FROM` | `TOTAL BILLED` |

Two decisions worth preserving:

- **The caller names a KIND; the daemon holds the words** (`src/main.cpp:380`).
  The tempting alternative was `&label1=…&label2=…`, and it turns a firm-branded
  endpoint into a general text-over-image renderer anybody can point at anything —
  on the firm's own domain, cached by every scraper that fetches it.
- **An unknown kind falls back to `invoice` rather than refusing**, same reason
  `theme_by_id` returns `THEMES[0]`: a card that reads as an invoice when the
  caller mistyped is cosmetic; a card that fails to render is a broken image in
  somebody's WhatsApp thread.

`booklet-mixed` exists because a set may span several counterparties, and there
`company` is the **issuing firm** — heading that card `BILLED TO` would name the
sender as the debtor (`src/main.cpp:409`).

`amount_label_for` (`src/main.cpp:477`) carries the sharpest constraint on this
surface: **`TOTAL PAYABLE` is a lie on a booklet the moment one of its invoices is
settled, and a card outlives that payment** — it is cached and forwarded by every
app that touches it. What does not move is the total *billed*, because booklet
membership is frozen when the link is minted. So the settled and due figures are
deliberately not renderable here at all, and trunk sends no date on a booklet
card either (a booklet has several, and an unlabelled date reads as *the* due
date).

## A5. The layout model

One composition routine, `Renderer::render` (`src/main.cpp:711`), with a
`has_rows` switch that rebalances the whole vertical budget.

```
1. fill(theme.bg)                                       canvas cleared
4. count numeral (2× label size, shared BASELINE) + label   y = 72
   · date right-aligned on the same line, "DUE …", drawn only if it fits
5. name — Fraunces Bold, auto-fitted 110→48 px (76→40 with rows)
6. business suffix on the NAME'S BASELINE, small + muted
7. divider rule
7b. up to 3 contents rows: label · leader dots · amount
    + a remainder row "+N ITEMS" with its own figure
    second divider rule
8/9. total: label left, figure right (with rows) or figure left at 160 px (without)
11. centre_vertically(bg), then fpng encode
```

Design is authored in a fixed **1200×630 design space**, and every literal goes
through `SPX()`/`SF()` (`src/main.cpp:39`) so the build-time `BILLPREVIEW_SCALE`
moves the whole card — canvas, positions and font sizes together. Ratios (the
rupee's 0.7 of the digit size) are already relative and are *not* scaled.

`IMG_W`/`IMG_H`/`CH` and the `SCALE` knob live in **`src/card_geometry.h`**,
included by both `main.cpp` and `fpng_card.cpp`. One header rather than two
derivations, because the encoder sizes a static buffer from those numbers and
two files that can disagree after a partial rebuild would not produce a
wrong-looking card — they would write `(w*ch+1)*h` bytes into a buffer sized
from a different `w`. `fpng_encode_card` also checks at run time that the canvas
it was handed is the one it was compiled for, and falls back to stock fpng if
not, so the failure is slow rather than wrong.

Rules that exist because of a specific defect:

- **`centre_vertically` is measured, not tuned** (`src/main.cpp:92`). The three
  layouts had top/bottom margins of 83/17, 77/16 and 83/148 against side margins
  of 80 — the invoice card had been bottom-starved since it was written, its
  total's descenders 16 px off the edge. Each could have been fixed by moving
  constants until it looked right, three times, and broken again by the next
  layout change. Instead the composition stays anchored top-left and the finished
  block is slid as a whole. Ink extent is tracked **per draw call**, two
  comparisons per glyph, rather than by scanning 756k pixels afterwards. The
  vacated band is repainted with the background, or row 0 would be duplicated as
  a stripe of the old layout.
- **Two runs of different sizes share a BASELINE, never a top edge**
  (`src/main.cpp:852`, `:864`, `:991`). `Font::draw` takes the top and derives the
  baseline from that face's ascent, so aligning tops leaves the larger run sitting
  visibly low.
- **The count numeral is drawn at twice the label size.** The first booklet card
  had "4 INVOICES" as the smallest text on a card whose entire subject is that it
  is a set — the one fact distinguishing it from the invoice card.
- **The amount in a contents row is drawn first and never truncated**
  (`src/main.cpp:694`): a shortened name is obviously shortened, a shortened
  number is just a wrong number.
- **Leader dots are drawn one glyph at a time** so the run ends on a whole dot
  rather than a clipped half, and they exist because across 1200 px the eye loses
  which amount belongs to which name.
- **The remainder row carries its own figure** (`src/main.cpp:887`). Three rows
  over a booklet of five with no overflow line is a card stating a complete
  contents list while missing two — a quiet lie. But `+2 ITEMS` with no figure is
  only half a fix: the three amounts plainly do not sum to the total underneath.
  With the remainder valued, the four figures add up exactly. If `morea` is
  absent (an older trunk), the row is drawn **unaligned** so it cannot be mistaken
  for a computed figure.
- **Fitting must know about tracking.** `fit_or_truncate_tracked`
  (`src/main.cpp:499`) exists because `measure()` only accounts for letter
  spacing when told; fitting a tracked label with the untracked helper
  under-measures by one step per character and lets it run off the right edge,
  where `blit_glyph` clips it **silently** — a real figure headed `TOTAL B` and
  nothing in any log.
- The date is drawn **only if it genuinely fits** beside the label
  (`src/main.cpp:816`); overlapping two runs is worse than dropping the less
  important one.

`split_business_suffix` (`src/main.cpp:319`) peels a trailing `Pvt Ltd`, `LLP`,
`Inc.` etc. onto the name's baseline beside it — on its own line it read as a
second fact about the company and spent ~40 px of a 630 px card on two words.

## A6. Fonts, glyphs and what cannot be drawn

Three faces, embedded as `xxd`-generated headers in `src/gen/` (regenerated by
the Makefile from `assets/`): **Fraunces Bold** (the name), **DM Mono Medium**
(labels, date, amount digits, contents rows) and **Inter** (the `₹` glyph only).
Embedding is what lets the sandbox blank the filesystem down to the binary.

`glyph_get` (`src/glyph_cache.cpp:16`) caches rasterised glyphs keyed by
`(font pointer, codepoint, scale)`. stbtt produces greyscale alpha and colour is
applied at blit time, so **one raster serves every colour**. The cache is bounded
at 8192 entries and **cleared wholesale when full** (`glyph_cache.cpp:27`): the
key space is finite but large — auto-fit measures every glyph at ~40 scales and
untrusted names vary the codepoints — and clearing is safe because every
reference returned is to a post-clear entry, so none can dangle. The unit's
`MemoryMax` is the hard backstop.

`prewarm` (`src/main.cpp:1653`) renders five representative cards before the
accept loop, covering both kinds *because their labels share almost no glyphs* —
a cold booklet render would otherwise rasterise the whole label face on the first
customer who opened one. Because this is one long-lived process, those glyphs
persist for its whole life.

**What it cannot draw: anything outside the three faces' coverage, which in
practice means Latin.** The UTF-8 layer is fine — `next_utf8`
(`src/main.cpp:217`) is a validating decoder. What is missing is glyph
*coverage*: measured against the live daemon, `कावेरी हार्डवेयर Pvt Ltd` renders
as correctly-sized, correctly-spaced **empty boxes**, because Fraunces has no
Devanagari.

Bundling a face is not the whole fix. **stb_truetype does no shaping** — it maps
codepoints to glyphs one for one — so an Indic script would come out with
unattached matras and no conjuncts: wrong in a way that looks plausible to a
reader who cannot read it. Doing it properly means HarfBuzz, a real dependency
decision for a static binary under this sandbox.

## A7. Concurrency, crash posture, and the fork that was removed

**One long-lived process, connections served sequentially, no fork and no
threads** (`run_daemon`, `src/main.cpp:1609`). `accept` handles one connection to
completion before the next, with `listen(srv, 128)` so a burst of unfurls queues
in the kernel.

The reason fork-per-request was **removed** is written at `src/main.cpp:1609`:
*a fork-per-request model turns "send a malformed name" into a fork + page-table
setup + crash + stack-unwind + reap cycle we pay for and the attacker does not* —
a cheap way to spin up a storm of processes whose only job is to die. Crash
containment became a resource-exhaustion DoS.

What replaced it is **prevention, in three places**:

1. **A total parse.** `next_utf8` returns U+FFFD for every malformed, overlong,
   surrogate or out-of-range sequence, consumes at least one byte on error so a
   hostile string always makes progress, and never reads past `end`
   (`src/main.cpp:208`). It replaced an ad-hoc decoder that understood only `₹`
   and fed every other high byte through as a raw code point — which both garbled
   real Unicode names and was exactly the kind of unchecked byte-poking a crafted
   name could probe.
2. **Every raster write is clipped** inside `Canvas::rect` and
   `Canvas::blit_glyph` (`src/main.cpp:158`, `:179`) — bounds-checked per pixel,
   so no coordinate arithmetic can write outside the buffer.
3. **Every input is bounded** before it reaches the shaper (A3).

**A fourth hole, found 2026-09-13 and closed: the daemon could die before it
ever served a request.** `run_daemon` copied the socket path out of the
environment with `strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1)`, and
zig's libc implements the `strn*` family by scanning the source for the
terminator with 64-byte vector loads (`mem.findScalarPos`, one `vpcmpeqb
(%rsi,%r8), %zmm0, %k1`) which read up to 63 bytes PAST it. Environment strings
live at the very top of the initial stack, so whenever the path ended within 64
bytes of that boundary the scan crossed into unmapped memory: SIGSEGV after
`socket()` and before `bind`, having printed `[ok] renderer ready` and nothing
else, so the only symptom was a socket that never appeared.

It was in every build ever made, including the one that was in production, and
it survived there only because of what its unit happened to put in the
environment — a future `Environment=` line in that unit would have been a crash
loop under `Restart=always`. The path is now copied by a bounded loop of our
own, and an over-long path is **refused** rather than truncated, because a
silently shortened socket path is a daemon listening where nginx is not looking.
`tests/socket_path_startup.py` is the guard; it has to drive `os.execve` itself,
because the first version launched from a shell and PASSED against the broken
binary.

The general lesson is bigger than the one call site: **this binary's libc
over-reads on every `strn*`/`strlen` it does**, and the reason that is harmless
everywhere else is that every other string it touches lives on the heap or in
`.bss`, surrounded by mapped pages. Anything reading a string that came from the
environment, or that sits at the end of a mapping, needs a bounded loop rather
than a libc call.

The `try`/`catch (...)` around `handle_client` (`src/main.cpp:1639`) is the
*backstop for allocation/size failures only*, and the comment says so: anything
memory-unsafe is prevented upstream, not caught. A malformed request drops one
connection (nginx returns 502 for it) and the next is served; the glyph cache
survives.

**Verified, because the release flags make it look doubtful:** `LDFLAGS_REL`/
`CXXFLAGS_REL_BASE` carry `-fno-unwind-tables -fno-asynchronous-unwind-tables`
(`Makefile:122`). Compiling an equivalent throw/catch with the same flag set
through `zig c++ -target x86_64-linux-musl` produces a binary that still contains
`.eh_frame` and `.eh_frame_hdr` and links `__gxx_personality_v0` — clang forces
unwind tables when C++ exceptions are enabled, so **the catch does work in the
release build**. Note that the Makefile's own legend at `Makefile:103` still claims
`-fno-exceptions` is passed; it is not (see Part C).

Measured performance (2026-09-13, whole request through the FastCGI socket,
1200×630, interleaved A/B against the previous build at every step):

| on the deploy host | whole request |
|---|---|
| before any of this (2026-09-12) | **8.1 ms** |
| `fpng`'s scratch buffers become process-owned | 2.3 ms |
| `canvas.fill` writes a pixel, not four bytes | — |
| centring becomes a pointer offset | 1.6 ms |
| the deflate's run scan goes eight pixels wide | 1.4 ms |
| the filter and the checksum widen to AVX | 1.2 ms |
| the glyph blit clips once, then blends eight at a time | **1.0 ms** |

Every one of those is byte-identical output; `tests/compare_renders.sh` is what
says so, and for the three that only have a vector path on x86 it has to be run
ON THE BOX, because the dev Mac is arm64 and would prove nothing about them.

**Name the machine or the number misleads.** The 2.52 ms this section used to
quote was a Mac figure presented as the render cost, and it was out by 3.2x for
the only machine that serves a customer. The largest single win of the lot —
`fpng` allocating two ~3 MB scratch buffers per call, 1479 minor page faults a
card under static musl — is worth 5.2x on the box and **1.02x on the Mac**,
because macOS's allocator caches the block. Measuring it locally would have
concluded there was nothing there.

**Two of the wins were the same bug in different functions**, and neither looked
like what it was. `canvas.fill` and `blit_glyph` both stored through a
`uint8_t *` into a buffer whose own pointer and dimensions sat beside it in the
same object, so the compiler reloaded all three after every store: 930 µs and
~150 µs of pure reloading, invisible when either loop was benchmarked on its own
and obvious in situ. Worth grepping for a third.

**And twice the profile said SIMD when the answer was bookkeeping.** `perf`
annotated `blit_glyph` as scalar `movzbl`/`imul`/`add` with no vector registers,
which reads as "needs vectorising"; counting first showed four bounds
comparisons per pixel answering "no" 65,000 times a card, and removing them was
worth 9% against the 6% the vector blend then added. Count before widening.

What is left is `fpng_encode_card` at ~64% of CPU, and the bulk of that is the
deflate's bit accumulator: each symbol's position depends on the total bit
length of every symbol before it, so it cannot be parallelised without a
two-pass design. Single threaded, so one slow render is a queue — fine at unfurl
volumes, and the thing to watch if the card ever grows work.

No per-request logging, deliberately (`src/main.cpp:1397`): a hot path serving
untrusted input, and in a long-lived process a line per card would sit in a
never-flushed stdout buffer. Only startup and errors are logged.

## A8. Build

`make` targets: `dev` (host debug), `mac`, `san` (ASan+UBSan), `prof`, and
`release`, which cross-compiles a **33-variant matrix** via `zig c++` + musl —
six x86_64 microarchitectures, four arm64, macOS arm64, each in all three
protocols — so provisioning a new host is an `scp`, not a rebuild.

Two traps in the matrix:

- **`x86_64-v4-znver3` and `x86_64-v3-skx` are built for CPUs with no AVX-512**,
  so despite the `v4` in the first name they are v3-level binaries. Choosing by
  filename errs safe (a v3 binary runs on v4 hardware) but the names do not mean
  what they say.
- If unsure, **`x86_64-generic-fcgi`** (`-mcpu=x86_64_v3`, AVX2, no AVX-512) is
  safe on any post-2015 server.

`SCALE` is a build-time knob (`Makefile:60`, `src/card_geometry.h`) and it is a
**contract with trunk**: trunk declares 1200×630 in `og:image:width/height`
(`bill_render_routes.go`, `cardImageWidth`/`cardImageHeight`), so a binary built
at another scale silently makes the markup lie, and several scrapers then
letterbox or drop the image. `trunk/scripts/smoke-dense.sh` reads the PNG's own
IHDR after every deploy and fails if it is not exactly that size.

**The `$(SRCS)` and `$(DEPS)` prerequisites on the release targets are
load-bearing** (`Makefile:166`). Without them the targets depended only on the
generated font headers, which change about once a year — so after any edit to
`main.cpp`,
`make out/billpreview-<variant>` printed "is up to date" and left the previous
binary in place. That is not a slow build, it is **a deploy of the wrong binary,
announced in green**: caught on 2026-09-11 when the card-kinds build turned out
to be the one from 2026-09-01, byte for byte.

Vendored third-party sources in `src/vendor/`, deliberately vendored so the
binary stays one static file with no package dependencies:

- `stb_truetype.h` — glyph rasterisation (public domain / MIT).
- `stb_image.h`, `stb_image_write.h` — image IO (not on the card path).
- `fpng.{h,cpp}` — the fast PNG encoder used for output; `fpng_init()` runs once
  at `Renderer::init`. Uses PCLMUL for CRC32 on x86, hence `-mpclmul` in the
  release flags. **It is not in `$(SRCS)`**: `src/fpng_card.cpp` `#include`s it
  and the Makefile compiles that instead, so it is in `$(DEPS)` — a dependency
  every target rebuilds on, but not a translation unit of its own. Compiling
  both would be two definitions of every fpng symbol.

`src/fpng_card.cpp` is the only local code that touches the encoder, and it
exists because **fpng allocates two ~3 MB scratch buffers on every call** — its
own filtered-scanline buffer, and the caller's output vector, which it resizes
to the whole raw image before shrinking it back to the ~78 KB a card comes to.
Under static musl both are over the mmap threshold, so that was **1479 minor
page faults per card** (counted with `getrusage`) and 6 ms of an 8 ms render.
`fpng_encode_card` keeps both for the life of the process; the render then
allocates nothing at all. Output is byte-identical and `make test` is what says
so. The file carries the full measurement, including what was tried and
rejected — specialising the scan loops on the compile-time width was worth 3%
and is deliberately absent, so every hot loop in `vendor/fpng.cpp` is still
upstream's and a vendor bump stays a file copy.

### Three optimisations that were BUILT AND MEASURED AND REJECTED (2026-09-13)

Recorded so nobody spends the day again. Each was implemented fully and
measured on the deploy host, release builds, both daemons up with requests
alternated between them.

**A Huffman table trained on our own cards.** fpng supports this
(`FPNG_TRAIN_HUFFMAN_TABLES`, `g_huff_counts`, `create_dynamic_block_prefix`);
the table was trained over a 48-card corpus covering all twelve palettes and all
four card shapes, and it works — **6.3% smaller than stock, 0.46% off the
per-image optimum** (worst 3.02%), which is essentially all of the 6.7% that a
fixed table can win. It is also **11-16% SLOWER**, consistently, on every card
kind. The likely mechanism is the `if (match_len == 4)` heuristic in the deflate
loop: a table that makes literals cheap tips that comparison toward emitting
four literals instead of one match, so the encoder writes fewer bits but more
symbols, and the bit-packer's cost is per symbol. Smaller output, more work.
Revisit only if wire bytes ever matter more than CPU; the method is above and
takes about an hour.

**Not to be confused with the run scan, which WAS worth it** — see
`src/fpng_card.cpp`'s `match_scan_vec`, which vectorises the loop that finds
where a run of identical pixels ends and is worth 8-12%. The item below is about
loop BOUNDS, which is a different and worthless change.

**Compile-time scan bounds in the deflate.** Constant `bpl`, no filter tail loop,
and the per-flush `dst_ofs + 8 > dst_buf_size` test removed — that test runs
~189,000 times a card. Measured **+3.5% and -1.9%**: noise. Not worth a
permanent copy of a vendored hot loop. Note also that removing the bounds check
is only safe if the output buffer is sized for the true worst case, which is
**two bytes per filtered input byte** (15 bits a symbol on input that is not a
card), not the stored-block size — the first attempt crashed `make test`'s noise
image with a bus error, and fpng's bounds check was the only thing that had ever
stopped it.

**PGO.** Unreachable for the shipped artifact: zig accepts
`-fprofile-instr-generate`, emits the counter sections, and links **no profile
runtime at all** for `x86_64-linux-musl` — an instrumented build runs and writes
nothing. Measured where it is reachable (g++ on the box, same flags): **-2.0%
and +0.7%**, noise. An earlier "-4.1%, 6/6" was against a plain `-O3` baseline
and was mostly a proxy for the `-Ofast -funroll-loops -flto` we already pass.
And gcc's build, however tuned, is **8-12% slower than the shipped clang/musl
one, 0 of 10 repetitions faster** — so adopting the box as build machine to gain
PGO loses more than PGO could return. The Makefile's `pgo-*` targets are also
inert for the release path: they use the native compiler, drive `test.sh` (the
LEGACY TAB protocol, not the deployed FastCGI one), instrument at `-O2` while
building at `-Ofast`, and the daemon never exits so the profile is never written.

`src/gen/font_*.h` are generated, not written — regenerate with `make` after
changing `assets/`.

## A9. Testing

`make test` (`tests/fpng_card_test.cpp`) is the only automated suite, added
2026-09-12 with the buffer-reuse change. **103 assertions**, and its whole
subject is that `fpng_encode_card`'s bytes equal stock fpng's: all twelve real
cards in `test_out/`, plus flat, noise, gradient, one-stray-pixel-in-the-last-row
and a deliberately wrong geometry, each encoded through both paths and then
decoded back with `fpng_decode_memory` to prove the result is a PNG carrying the
pixels it was given rather than merely 78 KB that compares equal to another
78 KB.

Two things about it are load-bearing and easy to undo by tidying:

- **It encodes stock first and the reused-buffer path second**, so the scratch
  buffer always holds the PREVIOUS card when it is filled. Staleness is the
  hazard that reuse introduces and that ordering is what looks for it. Reverse
  the two calls and the suite still passes while testing less.
- **It is built `-O2` without `-ffast-math` or `NDEBUG`**, so fpng's own asserts
  are live and the two encoders are not being compared under flags that could
  change either of them.

Three negative controls were executed against it, each confirmed to compile
first and to fail on the guard's own message: the filter loop starting at `y=1`
so the first scanline is left stale from the previous render (caught on every
card); the geometry guard removed (caught — a 64×40 input produced 72,145 bytes
against stock's 10,365); the IEND tail written one byte early (caught).

Two more gates landed 2026-09-13:

- **`tests/compare_renders.sh <a> <b>`** renders 22 cards through two builds and
  diffs the bytes — every kind, all twelve theme ids, rows and none, the overflow
  row with and without its figure, the name lengths that drive the auto-fit, a
  Devanagari name (boxes today, but they must be the SAME boxes) and a
  nonsense-input case. Any change claiming to be output-neutral runs this. Its
  first draft used invented theme ids, which fall back to `THEMES[0]`, so twelve
  theme cases were twelve copies of one and all reported ok.
- **`tests/socket_path_startup.py <binary>`** sweeps the environment size and
  the path length and asserts the daemon binds every time — the guard for the
  startup SIGSEGV in A7.

**Nothing covers layout, kinds, caps or the parse.** What exists for those:

- `test.sh` — starts a daemon, fires a battery of requests, writes PNGs into
  `test_out/` and reports timings. It speaks the **legacy tab protocol** and its
  socket is `/tmp/billpreview.sock`, so it exercises the default build, not the
  deployed FCGI one.
- `fcgi_client.py` — speaks FastCGI from a shell, and is the only way to exercise
  the deployed build without standing up nginx:
  ```
  ./fcgi_client.py --sock /tmp/billpreview.sock --get 'company=Acme Ltd&amount=1,000.00' -o card.png
  ./fcgi_client.py --sock /tmp/billpreview.sock --post 'company=Acme Ltd&amount=7,08,000.00&kind=booklet&count=6' -o booklet.png
  ```
- `margins.py`, `longrun_ipc_generate.sh` — measurement helpers.
- **The real regression gate lives in trunk**: `smoke_card` in
  `trunk/scripts/smoke-dense.sh:521` runs after every trunk deploy. It asserts
  three things, each for a failure with a precedent (see Part B).

Consequence: **a change to the LAYOUT is still verified by looking at PNGs and
by trunk's smoke.** If you change the layout, regenerate `test_out/` and compare;
if you change kinds or the wire, run `smoke-dense.sh`'s card section. Note that
regenerating `test_out/` also changes `make test`'s fixtures, which is fine —
the suite asserts the two encoders agree on whatever it is given, not that any
particular bytes come out.

## A10. How to make common changes

**Add a field.** Add the key to `parse_qs` (`src/main.cpp:1196`) — one place, all
three backends — a field to `CardFields`, and its **cap** to `build_card`. A field
with no cap in `build_card` is an unbounded input reaching a C++ shaper. Then draw
it in `render`. trunk's side is `setCardRows`/`cardURLFor` in
`bill_render_routes.go`.

**Add a card kind.** Extend `CardKind` (`:391`), `kind_by_id` (`:398`),
`name_label_tail` (`:421`) and `amount_label_for` (`:477`). Keep the words in the
daemon. Keep the unknown-value fallback. Add a `prewarm` sample if the new labels
introduce glyphs the existing ones do not. Then teach `smoke-dense.sh` to prove
the new kind differs from an invoice card built from the same fields — the
existing booklet check exists precisely because a daemon that ignores `&kind=`
renders a plausible-looking card asserting one payable total over a set.

**Change the layout.** Compose downwards from the top as the existing code does
and let `centre_vertically` balance it; do not add a compensating margin
constant. Anything drawn must go through a `fit_or_truncate*` helper —
`blit_glyph` clips silently. Use `SPX()`/`SF()` for every pixel literal or the
`SCALE` knob stops working. Regenerate `test_out/` and look at it.

**Change the card size.** Change nothing here — change `SCALE` at build time and
`cardImageWidth`/`cardImageHeight` in trunk **in the same change**, or the smoke
fails (which is the intended outcome).

**Add a script/font.** Adding a face to `assets/` and a `gen/` header is easy and
mostly wrong on its own; see A6. Budget for HarfBuzz or accept boxes.

## A11. Known gaps

- **The automated assertions cover the PNG encoder, output-neutrality and
  startup** (`make test`, `tests/compare_renders.sh`, `tests/socket_path_startup.py`
  — A9). Layout, card kinds, the input caps and the parse have none; for those
  the gate is still eyeballing `test_out/` and `smoke_card` in trunk.
- **The libc over-reads past a string's terminator** (A7). Closed at the one
  call site where it could fault; the hazard is structural and lives in zig's
  `mem.findScalarPos`.
- **Latin only** (A6), recorded rather than unnoticed.
- **Single-threaded**; one slow render is a queue.
- **No `Cache-Control`/`ETag`** on the FastCGI response.
- **No state beyond the query string**, so the card cannot express "this link is
  passphrase-protected" or "this link was withdrawn". trunk handles that by not
  emitting an `og:image` for those bills at all.
- `handle_client_fcgi` ignores `FCGI_BEGIN_REQUEST`'s role and flags entirely and
  answers any record stream that reaches `FCGI_STDIN` end-of-stream.
- **The theme ladder flips light/dark on the parity of the paise total** — see
  Part C; this is a real behaviour, not a documented one.

---

# Part B — the deployed daemon (`billpreview/`)

`billpreview/` in the monorepo contains **only `README.md`** — operational
documentation for the running daemon. The source is this repo.

## B1. How it runs

A **hardened SYSTEM unit** (`deploy/billpreview.service` here; installed as
`/etc/systemd/system/billpreview.service`):

```
ExecStart=/usr/local/bin/billpreview        # the x86_64-v4-znver4-fcgi build
Environment=BILLPREVIEW_SOCKET=/run/billpreview/billpreview.sock
User=billpreview  Group=www-data  UMask=0007
RuntimeDirectory=billpreview (0750)
```

The socket path comes from `BILLPREVIEW_SOCKET` (`src/main.cpp:1574`); the
compiled default `/tmp/billpreview.sock` (`src/main.cpp:47`) is the dev-harness
value only. **It has not been a user unit or a `/tmp` socket since 2026-09-01** —
and that stale claim is worth remembering because of *how* it wastes time:
`systemctl --user list-units` shows nothing (there is no user unit), the system
scope shows it fine, and a restart aimed at a home-directory binary changes
nothing about what is running. **Read `systemctl cat billpreview` first.**

The sandbox mirrors billpdf's and is tight: `PrivateUsers`, `PrivateNetwork` with
`RestrictAddressFamilies=AF_UNIX`, `IPAddressDeny=any`,
`TemporaryFileSystem=/:ro` with **only the binary bound back**,
`MemoryDenyWriteExecute`, `SystemCallFilter=@system-service` minus `@resources`
and `@privileged`, `MemoryMax=256M`, `TasksMax=32`. Because the fonts are
embedded, the process reads nothing from disk and a compromised one sees a
filesystem containing its own binary and nothing else.

**Cost of a change:** a new file the daemon must read is a **unit change, not a
chmod**. A new syscall is a seccomp kill plus `Restart=always`, i.e. a crash loop
named in the journal.

## B2. Deploying a new build

```
scp out/billpreview-x86_64-v4-znver4-fcgi docpilot:/tmp/billpreview-new-fcgi
sudo install -m 0755 -o root -g root /tmp/billpreview-new-fcgi /usr/local/bin/billpreview
sudo systemctl restart billpreview
journalctl -u billpreview -n 5     # "[ok] listening on /run/... [FCGI]"
```

Keep the previous binary beside it (`billpreview.bak-<date>`) — rollback is a copy
and a restart, and a release build reproduces in ~20 s. **Pick the `…-fcgi`
artifact** (A2). For an unfamiliar host, `x86_64-generic-fcgi`.

**Socket permissions.** `Group=www-data` + `UMask=0007` means the socket comes up
group-writable to nginx's own group, so no group surgery is needed today. When it
did (mode 0775 owned by the daemon's user), the fix was
`usermod -aG … www-data && systemctl restart nginx` — and the live lesson is that
**a `reload` is not enough after a group change**: a reloaded worker keeps its old
supplementary groups, which looks exactly like the fix not working.

## B3. Where the card lives, and why it is one fleet-wide URL

**`https://taxifo.com/preview.png`**, since 2026-09-11, for every firm.

It used to be `api.taxifo.com/og/card.png` — **one nginx location block per firm
hostname, and the block existed on exactly one of them.** Measured on 2026-09-11:
`api.taxifo.com/og/card.png` served a PNG and `api2.taxifo.com/og/card.png`
served the web app's `index.html` with a **200**. So every card the second firm
ever emitted, for the whole life of that firm, was a broken image in somebody's
chat thread, and nothing reported it — an SPA catch-all answers 200 with HTML,
which every status-only check calls healthy.

The fix rests on what this daemon *is*: it knows nothing about firms, it draws
what the request says. So pointing the whole fleet at one host leaks nothing, and
it removes the per-firm wiring that kept being forgotten. trunk points every
instance at it with `BILLPREVIEW_CARD_URL` (`bill_render_routes.go`,
`cardEndpoint`), which is **process-wide and is the one public URL trunk prints
that is allowed to be** — every other one names a *firm*, and a process-wide value
for those puts firm A's hostname in firm B's customer link. A **relative** value
is refused rather than joined, because a relative `og:image` is silently dropped
by every scraper. Unset falls back to the firm's own `/og/card.png`, which is
what every deployment did before the variable existed; the old per-firm path
still answers on `api.taxifo.com` for links already in the wild.

## B4. The deploy gate

`smoke_card` in `trunk/scripts/smoke-dense.sh:521` runs after every trunk deploy
and asserts three things, each for a failure with a precedent:

1. **It is a PNG** — content type *and* the file's own magic bytes. "A 200 does
   not mean the route exists"; an SPA catch-all is exactly how this broke.
2. **It is 1200×630**, read out of the PNG's own IHDR, because trunk declares
   those numbers and the daemon takes its canvas size from a build flag.
3. **A booklet card differs from an invoice card built from THE SAME FIELDS.** A
   daemon predating card kinds ignores `&kind=` and renders the invoice card
   headed `TOTAL PAYABLE` over a set of six invoices — identical bytes are the
   signature of that build and there is no other way to tell it apart from
   outside.

Check 3 carries its own lesson in the script: the first version compared a card
carrying a date against a booklet card carrying none, so the bytes differed for a
reason unrelated to kinds, and it **passed against the binary that predates kinds
entirely**. The two queries must differ only in `kind` and `count`, and the fixed
version was executed against that old binary before and after.

---

# Part C — where the existing notes are stale or unverifiable

Checked against this tree. Both READMEs are honest about *past* staleness and
still carry some of their own.

**In `preview-generator/README.md`:**

- **The theme section is wrong about light variants.** It says light themes are
  available "if you explicitly select them by `theme_id`". `theme_for_amount`
  (`src/themes.cpp:237`) picks the **light** variant when the paise total is even
  and the dark one when it is odd. Since trunk never sends `theme`, **every live
  card's light-or-dark appearance is decided by the parity of the total** — a real
  and undocumented behaviour, and a surprising one: two invoices a paisa apart
  unfurl in opposite colour schemes.
- "Rows are ignored on an `invoice` kind" is **false**. `build_card`
  (`src/main.cpp:1136`) accepts rows on either kind, with the reasoning written
  in ("a bill has a contents list too: its line items"), and trunk sends them for
  invoice cards (`bill_render_routes.go`, `billCardURL` → `invoiceCardRows`).
- The overflow row is documented as `"+ N MORE"`; the code draws **`+N ITEMS`** /
  `+N ITEM`, with no space after the plus (DM Mono is monospaced, so a space costs
  a full cell) — `src/main.cpp:895`.
- `morea` (the remainder's figure) is not documented at all in either README,
  despite being what makes the contents figures sum to the total.
- The "Daemon" and "Example systemd unit" sections describe running from
  `out/billpreview` under a `WorkingDirectory` with a `/tmp` socket. That is the
  dev harness; the real unit is `deploy/billpreview.service` and is hardened
  beyond recognition.
- "`[req] name=…` / `[render] … µs`" logging no longer exists — per-request
  logging was deliberately dropped (`src/main.cpp:1397`).
- The header line still describes the daemon as accepting "simple tab-delimited
  requests"; the deployed one speaks FastCGI.

**In `billpreview/README.md`:**

- Same `"+ N MORE"` and "rows ignored on invoice" staleness as above.
- Everything it says about the unit scope, the socket path, the FCGI-vs-tab trap
  and the one fleet-wide card URL **checks out** against `deploy/billpreview.service`,
  `src/main.cpp` and `smoke-dense.sh`.

**In the source itself:** the three this document listed on 2026-09-11 were
**fixed on 2026-09-12** and are recorded here only so nobody re-reports them —
`run_daemon`'s banner still advertised the fork that had been removed
(`src/main.cpp:1563`); the release-flag legend claimed `-fno-exceptions` was
passed when only `-fno-rtti` is, which would have made "restoring" it a compile
error (`Makefile:103`); and the protocol legend still called the tab protocol
the one "the Go daemon talks to", years after that client was deleted
(`Makefile:157`).

Nothing else in `src/` is known stale. The **line numbers throughout this
document are the hazard to watch**: they were exact when written and every one
of them moved by 4-12 lines on the next commit. They were remapped from the diff
on 2026-09-12; if you are reading a citation that lands on the wrong thing, that
is why, and the symbol name in the prose beside it is the durable half.

**Unverifiable from this tree:** which binary is actually installed on the box
(the artifact carries no version string and `printf`s only `[ok] listening …`);
whether the live nginx `location = /preview.png` matches what this repo assumes
(no vhost file for it is committed here). The render figures in A7 ARE
reproducible now — `make test` proves the encoder's output, and the A/B was run
by putting both binaries on the box behind separate sockets and alternating
between them, because that host is shared and two separate runs measure the
neighbours as much as the code.
