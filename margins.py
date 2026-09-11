"""Report the ink margins of a card PNG: top, bottom, left, right.

Eyeballing "does this look centred" is exactly the kind of judgement this
codebase keeps getting wrong, so measure it.
"""
import struct
import sys
import zlib


def load(path):
    d = open(path, "rb").read()
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        body = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h = struct.unpack(">II", body[:8])
        elif typ == b"IDAT":
            idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * 4
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b = prev[x]
            c = prev[x - 4] if x >= 4 else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, rows


def margins(path):
    w, h, px = load(path)
    bg = px[0][0:3]

    def ink(x, y):
        o = x * 4
        r = px[y]
        return abs(r[o] - bg[0]) + abs(r[o + 1] - bg[1]) + abs(r[o + 2] - bg[2]) > 24

    top = next(y for y in range(h) if any(ink(x, y) for x in range(w)))
    bot = next(y for y in range(h - 1, -1, -1) if any(ink(x, y) for x in range(w)))
    left = next(x for x in range(w) if any(ink(x, y) for y in range(h)))
    right = next(x for x in range(w - 1, -1, -1) if any(ink(x, y) for y in range(h)))
    return dict(w=w, h=h, top=top, bottom=h - 1 - bot, left=left, right=w - 1 - right)


if __name__ == "__main__":
    for path in sys.argv[1:]:
        m = margins(path)
        print(f"{path:24s} {m['w']}x{m['h']}  top {m['top']:3d}  bottom {m['bottom']:3d}"
              f"  left {m['left']:3d}  right {m['right']:3d}"
              f"   (top-bottom gap {m['top'] - m['bottom']:+d})")
