#!/usr/bin/env python3
"""Convert a raw 536x240 RGB565 big-endian framebuffer (GET /screenshot) to PNG. No dependencies.

usage: rgb565_to_png.py IN.raw OUT.png [--scale N] [--width 536 --height 240]
"""
import struct
import sys
import zlib


def main(argv):
    args = [a for a in argv[1:]]
    scale, w, h = 1, 536, 240
    for flag in ("--scale", "--width", "--height"):
        if flag in args:
            i = args.index(flag)
            val = int(args[i + 1])
            del args[i:i + 2]
            if flag == "--scale":
                scale = max(1, val)
            elif flag == "--width":
                w = val
            else:
                h = val
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    src, dst = args
    data = open(src, "rb").read()
    if len(data) != w * h * 2:
        print(f"error: {src} is {len(data)} bytes, expected {w * h * 2} ({w}x{h} RGB565)", file=sys.stderr)
        return 1
    # RGB565BE -> RGB888, replicating the top bits into the low bits so white is 255,255,255.
    lut_r = bytes(((v << 3) | (v >> 2)) for v in range(32))
    lut_g = bytes(((v << 2) | (v >> 4)) for v in range(64))
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            hi, lo = data[2 * (y * w + x)], data[2 * (y * w + x) + 1]
            v = (hi << 8) | lo
            px = bytes((lut_r[v >> 11], lut_g[(v >> 5) & 63], lut_r[v & 31]))
            row += px * scale
        line = b"\0" + bytes(row)
        rows.extend([line] * scale)

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(b"".join(rows), 6))
           + chunk(b"IEND", b""))
    open(dst, "wb").write(png)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
