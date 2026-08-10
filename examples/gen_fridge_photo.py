#!/usr/bin/env python3
"""One-off generator for examples/fridge_photo.png — a small, clearly-synthetic
placeholder image (a shelf background + a few colored blocks standing in for
items), used only because examples/skill_fridge_report_demo.lex needs SOME
real image bytes to push through show_report, and Tier-1's read_camera stub
honestly returns none (see that demo's module comment). Pure stdlib (zlib +
struct), no PIL — this repo's stub demos deliberately carry no ML/image deps.
"""
import struct
import zlib


def make_png(path, width, height, pixels):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        for x in range(width):
            raw.extend(pixels(x, y))
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


def fridge_pixels(x, y):
    bg = (235, 240, 238)  # pale interior wall
    shelf = (200, 205, 200)
    items = [
        (40, 40, 30, 40, (230, 230, 120)),   # milk carton
        (95, 55, 30, 25, (210, 60, 50)),     # tomato-ish
        (140, 35, 35, 45, (245, 245, 245)),  # yogurt tub
        (30, 100, 55, 20, (90, 160, 70)),    # lettuce
        (110, 105, 40, 15, (200, 150, 60)),  # cheese
    ]
    if y in (85, 165):
        return shelf
    for (ix, iy, iw, ih, color) in items:
        if ix <= x < ix + iw and iy <= y < iy + ih:
            return color
    return bg


if __name__ == "__main__":
    make_png("examples/fridge_photo.png", 200, 200, fridge_pixels)
    print("wrote examples/fridge_photo.png")
