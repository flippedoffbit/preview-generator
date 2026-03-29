#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# test.sh — start daemon, fire test requests, save PNGs, open for inspection
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BINARY="./out/billpreview"
SOCKET="/tmp/billpreview.sock"
OUT_DIR="./test_out"
DAEMON_PID=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[test]${RESET} $*"; }
ok()      { echo -e "${GREEN}[ok]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET} $*"; }
err()     { echo -e "${RED}[err]${RESET}  $*"; }

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
    echo "  run: make dev"
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.png   # clear previous run

# ── Start daemon ──────────────────────────────────────────────────────────────
info "starting daemon..."
"$BINARY" &
DAEMON_PID=$!

# wait for socket to appear (up to 3s)
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
send_request() {
    local name="$1" amount="$2" date="$3" outfile="$4"

    # send tab-delimited request, read 4-byte size prefix then PNG body
    # using python for binary-safe UDS communication
    python3 - <<EOF
import socket, struct, sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("$SOCKET")
sock.sendall(b"${name}\t${amount}\t${date}\n")

# read 4-byte little-endian size
raw = b""
while len(raw) < 4:
    chunk = sock.recv(4 - len(raw))
    if not chunk:
        sys.exit(1)
    raw += chunk

size = struct.unpack("<I", raw)[0]

# read PNG bytes
data = b""
while len(data) < size:
    chunk = sock.recv(size - len(data))
    if not chunk:
        break
    data += chunk

sock.close()

with open("${outfile}", "wb") as f:
    f.write(data)

print(f"  wrote {len(data)} bytes → ${outfile}")
EOF
}

# ── Test cases ────────────────────────────────────────────────────────────────
echo ""
info "sending test requests..."
echo ""

declare -a CASES=(
    "Rahul Sharma|12500|28 Mar 2026|01_rahul_12500.png"
    "Priya Patel|4999|27 Mar 2026|02_priya_4999.png"
    "Amit Kumar|150000|01 Jan 2026|03_amit_150000.png"
    "A|1|1 Jan 2026|04_minimal.png"                         # minimal fields
    "Very Long Name That Might Overflow|9999999|31 Dec 2026|05_overflow.png"  # stress
)

PASS=0; FAIL=0

for case in "${CASES[@]}"; do
    IFS='|' read -r name amount date outfile <<< "$case"
    outpath="$OUT_DIR/$outfile"

    if send_request "$name" "$amount" "$date" "$outpath" 2>&1; then
        # verify it's a valid PNG (check magic bytes)
        magic=$(xxd -p -l 4 "$outpath" 2>/dev/null || echo "")
        if [[ "$magic" == "89504e47" ]]; then
            ok "$outfile  (name='$name' amount='$amount')"
            ((PASS++))
        else
            err "$outfile — invalid PNG magic: $magic"
            ((FAIL++))
        fi
    else
        err "$outfile — request failed"
        ((FAIL++))
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo -e "  passed : ${GREEN}${PASS}${RESET}"
[[ $FAIL -gt 0 ]] && echo -e "  failed : ${RED}${FAIL}${RESET}" || echo -e "  failed : ${FAIL}"
echo "  output : $OUT_DIR/"
echo "─────────────────────────────────────"
echo ""

# ── Open images for inspection ────────────────────────────────────────────────
if [[ $PASS -gt 0 ]]; then
    info "opening images..."
    # macOS
    if command -v open &>/dev/null; then
        open "$OUT_DIR"/*.png
    # Linux with display
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

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
