#!/usr/bin/env python3
"""
render_fb.py — render a GREENFIELD framebuffer dump to PNG, decoded exactly as
the NorthMac Metal shader does.

Layout (column-major, the way the CRT scans): video byte for (col, scan) is at
raw offset col*256 + scan, col 0..79, scan 0..255. Within a byte bit7 is the
leftmost of 8 horizontal pixels. 640 px wide; 240 of 256 scanlines are visible.

    render_fb.py fb.raw out.png [--green|--amber|--white] [--full]
"""
import sys, struct, zlib

W, H_FULL, H_VIS, NCOLS = 640, 256, 240, 80
PHOSPHOR = {"--green": (112, 255, 112), "--amber": (255, 176, 0),
            "--white": (237, 232, 209)}


def render(raw_path, png_path, color, height):
    data = open(raw_path, "rb").read()
    if len(data) < NCOLS * 256:
        sys.exit(f"raw too short: {len(data)} bytes")

    fg = bytes(color)
    bg = bytes((0, 0, 0))
    rows = bytearray()
    for y in range(height):                 # scanline
        rows.append(0)                      # PNG filter: none
        for x in range(W):                  # pixel column
            col = x >> 3
            byte = data[col * 256 + y]
            bit = 7 - (x & 7)               # bit7 = leftmost
            rows += fg if (byte >> bit) & 1 else bg

    def chunk(tag, payload):
        c = tag + payload
        return struct.pack(">I", len(payload)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

    ihdr = struct.pack(">IIBBBBB", W, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))
    open(png_path, "wb").write(png)

    nz = sum(1 for b in data[:NCOLS * 256] if b)
    print(f"wrote {png_path}: {W}x{height}, {nz}/{NCOLS*256} non-zero video bytes")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    if len(args) != 2:
        sys.exit("usage: render_fb.py fb.raw out.png [--green|--amber|--white] [--full]")
    color = next((PHOSPHOR[f] for f in flags if f in PHOSPHOR), PHOSPHOR["--green"])
    height = H_FULL if "--full" in flags else H_VIS
    render(args[0], args[1], color, height)
