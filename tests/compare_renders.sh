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

fail=0; n=0
for q in "${CASES[@]}"; do
  n=$((n+1))
  python3 "$CLIENT" --sock "$TMP/a.sock" --get "$q" -o "$TMP/a.png" >/dev/null 2>&1
  python3 "$CLIENT" --sock "$TMP/b.sock" --get "$q" -o "$TMP/b.png" >/dev/null 2>&1
  sa=$(wc -c < "$TMP/a.png"); sb=$(wc -c < "$TMP/b.png")
  # An empty answer from both would compare equal and prove nothing.
  if [ "$sa" -lt 1000 ]; then
    echo "  FAIL  case $n: reference produced $sa bytes -- not a card"; fail=$((fail+1)); continue
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
exit $((fail > 0))
