#!/usr/bin/env python3
"""Generate a small Sitak PNG icon using only Python's standard library."""
import math
import struct
import sys
import zlib

SIZE = 128
pixels = bytearray([16, 24, 39] * SIZE * SIZE)

def set_pixel(x, y, color):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        i = (y * SIZE + x) * 3
        pixels[i:i + 3] = bytes(color)

def disk(cx, cy, radius, color):
    for y in range(max(0, cy-radius), min(SIZE, cy+radius+1)):
        for x in range(max(0, cx-radius), min(SIZE, cx+radius+1)):
            if (x-cx)**2 + (y-cy)**2 <= radius**2:
                set_pixel(x, y, color)

def line(x0, y0, x1, y1, color, width=2):
    steps = max(abs(x1-x0), abs(y1-y0), 1)
    for i in range(steps + 1):
        x = round(x0 + (x1-x0) * i / steps)
        y = round(y0 + (y1-y0) * i / steps)
        disk(x, y, width, color)

# Telescope-like orbit and a rising signal trace.
for deg in range(360):
    a = math.radians(deg)
    set_pixel(round(64 + 34*math.cos(a)), round(64 + 34*math.sin(a)), (158, 213, 255))
line(17, 90, 44, 68, (255, 200, 87), 2)
line(44, 68, 61, 78, (255, 200, 87), 2)
line(61, 78, 93, 39, (255, 200, 87), 2)
line(93, 39, 111, 25, (255, 200, 87), 2)
disk(64, 64, 5, (255, 242, 178))
for x, y in ((27, 35), (98, 98), (37, 105), (103, 57)):
    disk(x, y, 1, (255, 255, 255))

def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)

raw = b''.join(b'\0' + pixels[y*SIZE*3:(y+1)*SIZE*3] for y in range(SIZE))
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('!2I5B', SIZE, SIZE, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw, 9))
png += chunk(b'IEND', b'')
with open(sys.argv[1], 'wb') as f:
    f.write(png)
