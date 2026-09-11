#!/usr/bin/env python3
"""fcgi_client.py — speak FastCGI to the daemon, the way nginx does.

test.sh drives the LEGACY tab-delimited build. The binary actually deployed is
the FastCGI one, and until this existed there was no way to exercise it without
standing up nginx — which is how trunk shipped a client for the wrong protocol
and nobody noticed for months (the daemon reads the first eight bytes as a
record header, finds nonsense, and answers with a clean EOF that looks exactly
like the daemon being down).

  ./fcgi_client.py --sock /tmp/bp.sock --get 'company=Acme&amount=1000'
  ./fcgi_client.py --sock /tmp/bp.sock --post 'company=Acme&kind=booklet&count=6'
  ./fcgi_client.py --sock /tmp/bp.sock --get '' -o out.png

Prints the response status line and headers to stderr, writes the body to -o
(default: stdout, so `| wc -c` works). Exit status is 0 when the daemon
answered at all, 1 when it dropped the connection.
"""
import argparse
import socket
import struct
import sys

FCGI_VERSION = 1
BEGIN_REQUEST, ABORT_REQUEST, END_REQUEST = 1, 2, 3
PARAMS, STDIN, STDOUT, STDERR, DATA = 4, 5, 6, 7, 8
FCGI_RESPONDER = 1
REQ_ID = 1


def record(rtype: int, content: bytes = b"") -> bytes:
    # Records carry at most 65535 bytes of content; callers chunk before this.
    assert len(content) <= 65535
    return struct.pack("!BBHHBB", FCGI_VERSION, rtype, REQ_ID, len(content), 0, 0) + content


def name_value(name: bytes, value: bytes) -> bytes:
    def length(n: int) -> bytes:
        return bytes([n]) if n < 128 else struct.pack("!I", n | 0x80000000)

    return length(len(name)) + length(len(value)) + name + value


def request(sock_path: str, params: dict, body: bytes) -> tuple[bytes, bytes]:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock_path)

    out = record(BEGIN_REQUEST, struct.pack("!HB5x", FCGI_RESPONDER, 0))
    encoded = b"".join(name_value(k.encode(), v.encode()) for k, v in params.items())
    for i in range(0, len(encoded), 65535) or [0]:
        out += record(PARAMS, encoded[i:i + 65535])
    out += record(PARAMS)  # terminator
    for i in range(0, len(body), 65535):
        out += record(STDIN, body[i:i + 65535])
    out += record(STDIN)  # terminator — the daemon renders on this
    s.sendall(out)

    stdout, stderr = b"", b""
    while True:
        head = s.recv(8)
        if len(head) < 8:
            break
        _, rtype, _, clen, padlen, _ = struct.unpack("!BBHHBB", head)
        payload = b""
        while len(payload) < clen + padlen:
            chunk = s.recv(clen + padlen - len(payload))
            if not chunk:
                break
            payload += chunk
        payload = payload[:clen]
        if rtype == STDOUT:
            stdout += payload
        elif rtype == STDERR:
            stderr += payload
        elif rtype == END_REQUEST:
            break
    s.close()
    return stdout, stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", default="/tmp/billpreview.sock")
    ap.add_argument("--get", default="", help="query string, unencoded ampersands")
    ap.add_argument("--post", default="", help="form-encoded request body")
    ap.add_argument("-o", "--out", default="-")
    args = ap.parse_args()

    body = args.post.encode()
    params = {
        "QUERY_STRING": args.get,
        "REQUEST_METHOD": "POST" if body else "GET",
        "SCRIPT_NAME": "/preview.png",
        "SERVER_PROTOCOL": "HTTP/1.1",
    }
    if body:
        params["CONTENT_TYPE"] = "application/x-www-form-urlencoded"
        params["CONTENT_LENGTH"] = str(len(body))

    stdout, stderr = request(args.sock, params, body)
    if stderr:
        sys.stderr.write("[daemon stderr] " + stderr.decode("utf-8", "replace"))
    if not stdout:
        sys.stderr.write("no response — the daemon dropped the connection\n")
        return 1

    head, _, payload = stdout.partition(b"\r\n\r\n")
    sys.stderr.write(head.decode("utf-8", "replace") + "\n")
    if args.out == "-":
        sys.stdout.buffer.write(payload)
    else:
        with open(args.out, "wb") as fh:
            fh.write(payload)
        sys.stderr.write(f"{len(payload)} bytes -> {args.out}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
