#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test.sh — start daemon, fire test requests, save PNGs, measure perf
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BINARY="${1:-./out/billpreview}"   # override binary via first arg
SOCKET="/tmp/billpreview.sock"
OUT_DIR="./test_out"
DAEMON_PID=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[test]${RESET} $*"; }
ok()    { echo -e "${GREEN}[ok]${RESET}   $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET} $*"; }
err()   { echo -e "${RED}[err]${RESET}  $*"; }

# ── Cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
    if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        info "stopping daemon (pid $DAEMON_PID)"
        kill "$DAEMON_PID"
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ ! -x "$BINARY" ]]; then
    err "binary not found: $BINARY"
    echo "  run: make dev   (debug)  or  make mac  (optimised)"
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.png   # clear previous run

# ── Start daemon ──────────────────────────────────────────────────────────────
info "starting daemon: $BINARY"
"$BINARY" &
DAEMON_PID=$!

for i in {1..30}; do
    [[ -S "$SOCKET" ]] && break
    sleep 0.1
done
if [[ ! -S "$SOCKET" ]]; then
    err "daemon did not start (socket not found)"
    exit 1
fi
ok "daemon running (pid $DAEMON_PID)"

# ── send_request <name> <amount> <date> <outfile> ─────────────────────────────
# Prints a single line:  OK:<bytes>:<rtt_ms>:<render_ms>   on success
#                        ERR:<reason>                       on failure
send_request() {
    local name="$1" amount="$2" date="$3" outfile="$4"
    python3 - <<PYEOF
import socket, struct, sys, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect("$SOCKET")
except Exception as e:
    print(f"ERR:connect:{e}")
    sys.exit(0)

t0 = time.perf_counter()
sock.sendall("${name}\t${amount}\t${date}\n".encode())

# read 8-byte header: <4 bytes PNG size LE> <4 bytes render_us LE>
hdr = b""
while len(hdr) < 8:
    chunk = sock.recv(8 - len(hdr))
    if not chunk:
        print("ERR:truncated header")
        sys.exit(0)
    hdr += chunk

size, render_us = struct.unpack("<II", hdr)
render_ms = render_us / 1000.0

data = b""
while len(data) < size:
    chunk = sock.recv(size - len(data))
    if not chunk:
        break
    data += chunk

sock.close()
elapsed_ms = (time.perf_counter() - t0) * 1000

with open("${outfile}", "wb") as f:
    f.write(data)

print(f"OK:{len(data)}:{elapsed_ms:.2f}:{render_ms:.2f}")
PYEOF
}

# ── Test cases ────────────────────────────────────────────────────────────────
# Format: "name|amount|date|outfile"
declare -a CASES=(
    # normal names
    "Rahul Sharma|12,500.00|28 Mar 2026|01_rahul.png"
    "Priya Patel|4,999.00|27 Mar 2026|02_priya.png"
    "Amit Kumar|1,50,000.00|01 Jan 2026|03_amit.png"
    # business suffixes
    "Infosys Ltd|2,35,000.00|28 Mar 2026|04_infosys_ltd.png"
    "Tata Consultancy Services Limited|98,500.00|28 Mar 2026|05_tcs_limited.png"
    "Zeta Dynamics Pvt Ltd|12,000.00|15 Mar 2026|06_zeta_pvtltd.png"
    "Apex Ventures LLC|75,000.00|20 Mar 2026|07_apex_llc.png"
    "Blue River Inc|3,200.00|22 Mar 2026|08_blueriver_inc.png"
    "Meridian Partners LLP|55,000.00|10 Mar 2026|09_meridian_llp.png"
    # long names (auto-fit + ellipsis stress)
    "Very Long Company Name That Might Overflow The Canvas|9,999.00|31 Dec 2026|10_overflow.png"
    "Supercalifragilisticexpialidocious Global Holdings Private Limited|50,000.00|31 Dec 2026|11_superlong_suffix.png"
    # minimal
    "A|1.00|1 Jan 2026|12_minimal.png"
)

echo ""
info "sending ${#CASES[@]} requests..."
echo ""

PASS=0; FAIL=0
declare -a RENDER_TIMES=()
declare -a RTT_TIMES=()

for case in "${CASES[@]}"; do
    IFS='|' read -r name amount date outfile <<< "$case"
    outpath="$OUT_DIR/$outfile"

    result=$(send_request "$name" "$amount" "$date" "$outpath" 2>&1)

    if [[ "$result" == OK:* ]]; then
        bytes=$(echo "$result"     | cut -d: -f2)
        rtt_ms=$(echo "$result"    | cut -d: -f3)
        render_ms=$(echo "$result" | cut -d: -f4)
        RENDER_TIMES+=("$render_ms")
        RTT_TIMES+=("$rtt_ms")

        # verify PNG magic
        magic=$(xxd -p -l 4 "$outpath" 2>/dev/null || echo "")
        if [[ "$magic" == "89504e47" ]]; then
            printf "  ${GREEN}✓${RESET} %-44s  render: %6s ms   rtt: %s ms\n" \
                "$outfile" "$render_ms" "$rtt_ms"
            ((PASS++))
        else
            err "$outfile — bad PNG magic: $magic"
            ((FAIL++))
        fi
    else
        err "$outfile — $result"
        ((FAIL++))
    fi
done

# ── Performance summary ───────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────────"
echo -e "${BOLD}  results${RESET}"
echo -e "  passed : ${GREEN}${PASS}${RESET} / $((PASS + FAIL))"
[[ $FAIL -gt 0 ]] && echo -e "  failed : ${RED}${FAIL}${RESET}"
echo "  output : $OUT_DIR/"

if [[ ${#RENDER_TIMES[@]} -gt 0 ]]; then
    render_csv=$(IFS=','; echo "${RENDER_TIMES[*]}")
    rtt_csv=$(IFS=','; echo "${RTT_TIMES[*]}")
    echo ""
    echo -e "${BOLD}  performance${RESET}"
    python3 - <<PYEOF
render = [$render_csv]
rtt    = [$rtt_csv]
n      = len(render)
print(f"  {'case':<6}  {'render':>9}  {'rtt':>9}")
print(f"  {'─'*6}  {'─'*9}  {'─'*9}")
for i,(r,t) in enumerate(zip(render,rtt)):
    print(f"  {i+1:<6}  {r:>8.2f}ms  {t:>8.2f}ms")
print()
print(f"  avg render : {sum(render)/n:.2f} ms")
print(f"  min render : {min(render):.2f} ms")
print(f"  max render : {max(render):.2f} ms")
print(f"  total      : {sum(render):.1f} ms  ({n} images)")
PYEOF
fi
echo "─────────────────────────────────────────────────────"
echo ""

# ── Open images for inspection ────────────────────────────────────────────────
if [[ $PASS -gt 0 ]]; then
    info "opening images..."
    if command -v open &>/dev/null; then
        open "$OUT_DIR"/*.png
    elif command -v eog &>/dev/null; then
        eog "$OUT_DIR"/*.png &
    elif command -v feh &>/dev/null; then
        feh "$OUT_DIR"/*.png &
    elif command -v xdg-open &>/dev/null; then
        for f in "$OUT_DIR"/*.png; do xdg-open "$f"; done
    else
        warn "no image viewer found — open $OUT_DIR/ manually"
    fi
fi

