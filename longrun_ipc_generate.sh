#!/usr/bin/env bash
# longrun_ipc_generate.sh — Generate 200,000 images via IPC, discard output, monitor memory externally

BINARY="./out/billpreview-mac-arm64"  # Adjust path as needed
SOCKET="/tmp/billpreview.sock"
ITERATIONS=200000
NAME="Test User"
AMOUNT="1,000.00"
DATE="30 Mar 2026"
DAEMON_PID=""

set -euo pipefail

# Cleanup on exit
cleanup() {
    if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "[info] stopping daemon (pid $DAEMON_PID)"
        kill "$DAEMON_PID"
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
}
trap cleanup EXIT

if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found: $BINARY"
  exit 1
fi

# Start daemon
"$BINARY" &
DAEMON_PID=$!

for i in {1..30}; do
    [[ -S "$SOCKET" ]] && break
    sleep 0.1
done
if [[ ! -S "$SOCKET" ]]; then
    echo "[err] daemon did not start (socket not found)"
    exit 1
fi

echo "[info] daemon running (pid $DAEMON_PID)"

generate_image() {
    python3 - <<PYEOF
import socket, struct, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("$SOCKET")
sock.sendall("${NAME}\t${AMOUNT}\t${DATE}\n".encode())
hdr = b""
while len(hdr) < 8:
    chunk = sock.recv(8 - len(hdr))
    if not chunk:
        sys.exit(0)
    hdr += chunk
size, _ = struct.unpack("<II", hdr)
received = 0
while received < size:
    chunk = sock.recv(min(4096, size - received))
    if not chunk:
        break
    received += len(chunk)
sock.close()
PYEOF
}

for ((i=1;i<=ITERATIONS;i++)); do
    generate_image
    if (( i % 1000 == 0 )); then
        echo "Completed $i requests..."
    fi
done

echo "Completed $ITERATIONS requests."
