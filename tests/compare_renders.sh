#!/usr/bin/env bash
# Render a battery of cards through TWO builds and diff the bytes.
#
# make test proves the PNG ENCODER against stock fpng. It says nothing about
# the drawing above it, and this repo's documented gate for that is "regenerate
# test_out/ and look at it" -- fine for a layout change somebody is judging by
# eye, useless for a change that is supposed to alter nothing at all.
#
# This is that second gate. Any change claiming to be output-neutral -- a
# faster fill, a refactor, a compiler flag, a vendor bump -- must pass it, and
# it is the only thing standing between "the cards look the same" and "the
# cards ARE the same".
#
#   tests/compare_renders.sh <binary-a> <binary-b>
#
# Both must be FastCGI builds (…-fcgi, or `make dev` with -DPROTO_FCGI).
#
# BUILD BOTH WITH THE SAME OPTIMISATION FLAGS. The release flags include
# -funsafe-math-optimizations, which changes float rounding in glyph
# positioning: the same source at -Ofast and at -O2 differs by one pixel on 19
# of the 22 cards below. Comparing a Makefile release binary against a hand-built
# -O2 one therefore reports a difference that is nothing to do with the change
# under test -- which cost an hour on 2026-09-13 and produced a confident, wrong
# conclusion about a centring change that was in fact byte-neutral.
set -u

A="${1:?usage: compare_renders.sh <binary-a> <binary-b>}"
B="${2:?usage: compare_renders.sh <binary-a> <binary-b>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$HERE/fcgi_client.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill "${PID_A:-0}" "${PID_B:-0}" 2>/dev/null' EXIT

# Every kind, every theme, and the layout branches: rows and no rows, a
# business suffix and none, an overflow row with and without its figure, the
# name lengths that drive the auto-fit, and a non-Latin name (boxes today --
# but they must be the SAME boxes).
CASES=(
  "company=Acme%20Industries%20Private%20Limited&amount=7,08,000.00&date=2026-09-01"
  "company=A&amount=9.00&date=2026-12-31"
  "company=Zeta%20Traders%20LLP&amount=1,38,414.00"
  "company=Deshpande%20%26%20Iyer%20Associates&amount=7,08,000.00&kind=booklet&count=6"
  "company=Deshpande%20%26%20Iyer%20Associates&amount=7,08,000.00&kind=booklet-mixed&count=12"
  "company=Meridian%20Infotech%20Solutions%20LLP&amount=2,10,000.00&kind=booklet&count=4&r1=Invoice%20one&a1=1,00,000.00&r2=Invoice%20two&a2=60,000.00&r3=Invoice%20three&a3=30,000.00&more=2&morea=20,000.00"
  "company=Kaveri%20Hardware%20%26%20Tools&amount=99,999.00&r1=Cotton%20yarn%2040s&a1=82,000.00&r2=Dyeing&a2=15,000.00&more=3"
  "company=%E0%A4%95%E0%A4%BE%E0%A4%B5%E0%A5%87%E0%A4%B0%E0%A5%80%20Pvt%20Ltd&amount=1,000.00"
  "company=Suryodaya%20Agro%20Foods%20Private%20Limited%20And%20Sons%20And%20Company&amount=12,34,56,789.00"
  "company=X&amount=0.00&kind=nonsense&count=abcd&more=99999"
)
# All twelve real theme ids, from src/themes.cpp. The ids matter: an unknown
# one silently falls back to THEMES[0], so a typo here turns twelve cases into
# twelve copies of one -- which is exactly what the first draft of this file
# did, and it looked like twelve passing checks.
for t in dark-purple dark-slate dark-amber dark-emerald dark-ice dark-rose \
         light-ivory light-stone light-sage light-sky light-peach light-lavender; do
  CASES+=("company=Theme%20Probe%20Pvt%20Ltd&amount=5,000.00&theme=$t")
done

start () { # $1 binary, $2 sockname -> echoes pid
  local sock="$TMP/$2.sock"
  BILLPREVIEW_SOCKET="$sock" "$1" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 200); do [ -S "$sock" ] && break; sleep 0.02; done
  [ -S "$sock" ] || { echo "FAIL: $1 never bound its socket"; exit 1; }
  echo "$pid"
}
PID_A="$(start "$A" a)" || exit 1
PID_B="$(start "$B" b)" || exit 1

# ── preflight: prove both daemons actually render, before comparing anything ──
#
# TWO NOTHINGS COMPARE EQUAL, and worse, two nothings that both fail the
# plausibility check below used to print "FAIL 22 of 22 cards differ" -- which
# reads like twenty-two real differences and is in fact one harness mistake.
# That happened for real on 2026-09-13: a build without -DPROTO_FCGI was handed
# to this script, spoke a protocol the client does not, answered nothing at all,
# and the summary said the cards differed. Feeding the tab-delimited protocol to
# a FastCGI build (or the reverse) fails SILENTLY -- the daemon reads the first
# bytes as a record header, finds nonsense, and closes cleanly -- which is the
# single most documented trap in this component, so the script must name it
# rather than let it look like a diff.
#
# Exit status is now three-valued: 0 identical, 1 the cards really differ,
# 2 the harness did not run. Anything automated should treat 2 as "no result".
probe () { # $1 = sock, $2 = label, $3 = binary
  # DELETE IT FIRST. Without this the second probe reads the FIRST probe's file
  # when the second daemon writes nothing, so a broken candidate inherits a
  # healthy reference's card and sails through -- which is exactly what the
  # first version of this preflight did, and it is the same stale-artifact
  # class as everything else this file guards against.
  rm -f "$TMP/probe.png"
  python3 "$CLIENT" --sock "$1" --get "company=Preflight&amount=1,000.00" \
    -o "$TMP/probe.png" >/dev/null 2>&1
  local sz=0
  [ -f "$TMP/probe.png" ] && sz=$(wc -c < "$TMP/probe.png")
  if [ "$sz" -lt 1000 ]; then
    echo "HARNESS: $2 ($3) answered $sz bytes, which is not a card."
    echo "         The likeliest cause is a build without -DPROTO_FCGI: speaking"
    echo "         FastCGI to it fails silently and looks exactly like this."
    echo "         Use a ...-fcgi artifact, or 'make dev' built with -DPROTO_FCGI."
    exit 2
  fi
  if [ "$(head -c 4 "$TMP/probe.png" | od -An -tx1 | tr -d ' \n')" != "89504e47" ]; then
    echo "HARNESS: $2 ($3) answered $sz bytes that are not a PNG."
    exit 2
  fi
}
probe "$TMP/a.sock" "reference" "$A"
probe "$TMP/b.sock" "candidate" "$B"

fail=0; n=0
for q in "${CASES[@]}"; do
  n=$((n+1))
  rm -f "$TMP/a.png" "$TMP/b.png"
  python3 "$CLIENT" --sock "$TMP/a.sock" --get "$q" -o "$TMP/a.png" >/dev/null 2>&1
  python3 "$CLIENT" --sock "$TMP/b.sock" --get "$q" -o "$TMP/b.png" >/dev/null 2>&1
  sa=0; sb=0
  [ -f "$TMP/a.png" ] && sa=$(wc -c < "$TMP/a.png")
  [ -f "$TMP/b.png" ] && sb=$(wc -c < "$TMP/b.png")
  # A daemon that stops answering mid-run ABORTS the comparison. It used to
  # count as one more failing case, so a daemon that died on case 3 reported
  # twenty differing cards.
  if [ "$sa" -lt 1000 ] || [ "$sb" -lt 1000 ]; then
    echo
    echo "HARNESS: case $n got $sa / $sb bytes -- a daemon stopped answering."
    echo "         Not a difference in the cards. Query: ${q:0:60}"
    exit 2
  fi
  if cmp -s "$TMP/a.png" "$TMP/b.png"; then
    printf "  ok    case %2d  %7d bytes\n" "$n" "$sa"
  else
    printf "  FAIL  case %2d  %d vs %d bytes  %s\n" "$n" "$sa" "$sb" "${q:0:52}"
    fail=$((fail+1))
  fi
done

echo
if [ "$fail" -eq 0 ]; then echo "ok    $n cards, byte-identical"; else echo "FAIL  $fail of $n cards differ"; fi
exit $((fail > 0))  # 0 identical, 1 they differ; 2 comes from the harness checks above
