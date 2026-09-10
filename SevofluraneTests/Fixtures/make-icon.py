#!/usr/bin/env python3
"""Writes fixture.ico: one entry per icon storage form PEResources decodes.

Five sizes, five encodings — 32-bit BGRA, 4-bit and 8-bit paletted, 24-bit,
and a PNG at 256 — so the parser's every branch has a picture to read. Each
image is a solid color with an opaque AND mask, which makes an assertion about
a decoded pixel a statement about the decoder rather than about art.
"""
import struct
import sys
import zlib

# size, bits per pixel, RGB
ENTRIES = [
    (16, 32, (0xE0, 0x30, 0x30)),
    (24, 4, (0x30, 0xE0, 0x30)),
    (32, 24, (0x30, 0x30, 0xE0)),
    (48, 8, (0xE0, 0xE0, 0x30)),
    (256, 0, (0x30, 0xE0, 0xE0)),  # 0 bits: stored as a PNG
]


def row_bytes(width, bits):
    return ((width * bits + 31) // 32) * 4


def dib(size, bits, rgb):
    red, green, blue = rgb
    palette = b""
    if bits <= 8:
        # Two entries: index 0 is unused, index 1 is the fill.
        palette = bytes([0, 0, 0, 0]) + bytes([blue, green, red, 0])
    stride = row_bytes(size, bits)
    rows = []
    for _ in range(size):
        if bits == 32:
            pixel = bytes([blue, green, red, 0xFF])
        elif bits == 24:
            pixel = bytes([blue, green, red])
        elif bits == 8:
            pixel = bytes([1])
        else:  # 4 bits: two pixels per byte, both index 1
            pixel = bytes([0x11])
        count = size if bits >= 8 else size // 2
        row = pixel * count
        rows.append(row + b"\0" * (stride - len(row)))
    mask_stride = row_bytes(size, 1)
    mask = (b"\0" * mask_stride) * size
    header = struct.pack(
        "<IiiHHIIiiII",
        40, size, size * 2, 1, bits, 0, 0, 2835, 2835,
        2 if bits <= 8 else 0, 0,
    )
    return header + palette + b"".join(rows) + mask


def chunk(kind, payload):
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def png(size, rgb):
    red, green, blue = rgb
    raw = b"".join(
        b"\0" + bytes([red, green, blue, 0xFF]) * size for _ in range(size)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main(path):
    images = [
        png(size, rgb) if bits == 0 else dib(size, bits, rgb)
        for size, bits, rgb in ENTRIES
    ]
    offset = 6 + 16 * len(images)
    directory = struct.pack("<HHH", 0, 1, len(images))
    for (size, bits, _), image in zip(ENTRIES, images):
        directory += struct.pack(
            "<BBBBHHII",
            size % 256, size % 256, 0, 0, 1, bits or 32, len(image), offset,
        )
        offset += len(image)
    with open(path, "wb") as out:
        out.write(directory + b"".join(images))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fixture.ico")
