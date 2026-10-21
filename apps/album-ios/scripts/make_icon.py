"""Create the app's geometric icon using only Python's standard library."""
from pathlib import Path
import struct
import zlib

size = 1024
rows = bytearray()
for y in range(size):
    rows.append(0)
    for x in range(size):
        background = (40, 91 + int(10 * y / size), 75)
        in_frame = 210 <= x <= 814 and 240 <= y <= 784
        border = in_frame and (x < 254 or x > 770 or y < 284 or y > 740)
        sun = (x - 650) ** 2 + (y - 400) ** 2 < 55 ** 2
        hill = in_frame and 260 < x < 770 and 740 >= y >= (510 + abs(x - 455) * 0.9 if x < 580 else 600 + abs(x - 670) * 0.8)
        rows.extend((245, 240, 221) if border or hill else (217, 198, 140) if sun else background)

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')
target = Path(__file__).resolve().parents[1] / 'Lightbox/Assets.xcassets/AppIcon.appiconset/icon-1024.png'
target.write_bytes(png)
print(f'Created opaque {size}x{size} app icon ({len(png)} bytes)')
