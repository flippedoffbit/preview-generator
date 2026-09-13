#!/usr/bin/env bash
# Prove WHICH theme the amount ladder selects — with no image library, no
# golden files, and no second build.
#
# The trick: render the same card twice through ONE daemon, once letting
# theme_for_amount choose and once pinning `theme=` explicitly, and compare the
# bytes. Identical bytes mean the ladder chose that theme. Rendering it a third
# time against a LIGHT variant is the control: if that matched too, the
# comparison would be proving nothing, and the check says so instead of passing.
#
# This is a different question from tests/compare_renders.sh, which asks whether
# two BINARIES agree. This asks whether one binary's ladder lands where its own
# docblock says, so it keeps working when there is nothing to compare against.
#
#   tests/theme_selection.sh <fcgi-binary>
#
# Exit: 0 all checks passed · 1 a check failed · 2 the harness could not run.
#
# WHY THIS EXISTS. Until 2026-09-13 theme_for_amount took the ladder's index and
# then added 6 — the light variant — whenever the paise total was EVEN. trunk
# never sends `theme`, so half of every firm's live cards came out light and
# which half was decided by the last digit of the money: correcting an invoice
# by one paisa inverted its link preview. Three documents (README, this repo's
# DOCUMENTATION.md, and the function's own docblock, which lists six dark themes
# and no light ones) described the behaviour without the parity step. All three
# agreed with each other and none agreed with the code, and nothing executable
# asked. That is what this file is for.
set -u

BIN="${1:?usage: theme_selection.sh <fcgi-binary>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$HERE/fcgi_client.py"
[ -x "$BIN" ] || { echo "not executable: $BIN"; exit 2; }
[ -f "$CLIENT" ] || { echo "missing $CLIENT"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill "${PID:-0}" 2>/dev/null' EXIT

BILLPREVIEW_SOCKET="$TMP/p.sock" "$BIN" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 200); do [ -S "$TMP/p.sock" ] && break; sleep 0.02; done
[ -S "$TMP/p.sock" ] || {
  echo "FAIL: $BIN never bound its socket."
  echo "  A FastCGI build is required (…-fcgi, or make dev with -DPROTO_FCGI)."
  echo "  A non-FastCGI build accepts the connection and answers nothing."
  exit 2
}

render () { # $1 query -> md5, or a loud non-hash
  rm -f "$TMP/o.png"
  python3 "$CLIENT" --sock "$TMP/p.sock" --get "$1" -o "$TMP/o.png" >/dev/null 2>&1
  [ -f "$TMP/o.png" ] || { echo "NOFILE"; return; }
  local sz; sz=$(wc -c < "$TMP/o.png" | tr -d ' ')
  # Read the size of THIS render, never a file left by the one before: a stale
  # artifact read back as a fresh one is how a broken candidate sails through.
  [ "$sz" -lt 1000 ] && { echo "EMPTY($sz)"; return; }
  md5 -q "$TMP/o.png" 2>/dev/null || md5sum "$TMP/o.png" | cut -d' ' -f1
}

fail=0
CO="company=Probe%20Pvt%20Ltd"

check () { # $1 amount, $2 expected theme id
  local q="$CO&amount=$1"
  local free pinned control
  free=$(render "$q")
  pinned=$(render "$q&theme=$2")
  control=$(render "$q&theme=light-ivory")
  case "$free$pinned" in *EMPTY*|*NOFILE*)
    echo "  HARNESS  $1: daemon answered nothing"; exit 2 ;;
  esac
  if [ "$pinned" = "$control" ]; then
    echo "  USELESS  $1: $2 and light-ivory render identically; this proves nothing"
    fail=$((fail+1)); return
  fi
  if [ "$free" = "$pinned" ]; then
    echo "  ok       $1 -> $2"
  else
    echo "  FAIL     $1 -> expected $2, got something else"
    fail=$((fail+1))
  fi
}

echo "ladder lands where theme_for_amount's docblock says:"
check "9.00"        dark-purple    # < Rs 1,000
check "5,000.00"    dark-emerald   # < Rs 10,000
check "25,000.00"   dark-amber     # < Rs 50,000
check "75,000.00"   dark-ice       # < Rs 1,00,000
check "2,00,000.00" dark-rose      # < Rs 5,00,000
check "7,08,000.00" dark-slate     # Rs 5,00,000+

# The parity regression itself. Comparing render(5,000.00) with render(5,000.01)
# directly would be wrong — the amount is PRINTED on the card, so two different
# amounts differ in bytes whatever theme they use, and that comparison can never
# pass. Ask instead whether each lands on the SAME theme.
echo
echo "one paisa apart, mid-band, must agree:"
check "5,000.00" dark-emerald
check "5,000.01" dark-emerald

# And the ladder must still be a ladder: a band edge SHOULD change the theme.
# Without this, "always return THEMES[0]" would pass everything above.
echo
echo "a band edge still changes the theme:"
check "999.99"   dark-purple
check "1,000.00" dark-emerald

echo
if [ "$fail" -eq 0 ]; then
  echo "ok    theme selection: 10 checks, 0 failed"
  exit 0
fi
echo "FAIL  theme selection: $fail of 10 checks failed"
exit 1
