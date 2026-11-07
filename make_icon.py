# -*- coding: utf-8 -*-
"""Генерация иконки приложения: двойная стрелка <-> на синем фоне."""
from PIL import Image, ImageDraw

S = 256
img = Image.new('RGB', (S, S), (23, 74, 124))
d = ImageDraw.Draw(img)

# рамка по краю
d.rectangle([0, 0, S - 1, S - 1], outline=(14, 46, 78), width=10)

def arrow(y, direction, color):
    """Горизонтальная стрелка: direction=+1 вправо, -1 влево."""
    x0, x1 = 44, S - 44          # концы стержня
    head = 46                    # длина наконечника
    half = 13                    # полутолщина стержня
    tip_half = 34                # полураствор наконечника
    if direction > 0:
        shaft = [(x0, y - half), (x1 - head, y - half),
                 (x1 - head, y + half), (x0, y + half)]
        tri = [(x1 - head, y - tip_half), (x1, y), (x1 - head, y + tip_half)]
    else:
        shaft = [(x1, y - half), (x0 + head, y - half),
                 (x0 + head, y + half), (x1, y + half)]
        tri = [(x0 + head, y - tip_half), (x0, y), (x0 + head, y + tip_half)]
    d.polygon(shaft, fill=color)
    d.polygon(tri, fill=color)

arrow(96, +1, (255, 255, 255))   # верхняя — вправо, белая
arrow(160, -1, (255, 176, 32))   # нижняя — влево, оранжевая

import struct
from io import BytesIO

BMP_SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128]

def make_dib(size):
    im = img.resize((size, size), Image.LANCZOS)
    buf = BytesIO()
    im.save(buf, 'BMP')
    dib = bytearray(buf.getvalue()[14:])
    struct.pack_into('<i', dib, 8, size * 2)  # biHeight = XOR + AND
    dib += b'\x00' * ((((size + 31) // 32) * 4) * size)  # маска AND
    return bytes(dib), 24

entries = []
for s in BMP_SIZES:
    dib, bits = make_dib(s)
    entries.append((s, bits, dib))
# 256 — обязательно PNG
buf = BytesIO()
img.resize((256, 256), Image.LANCZOS).save(buf, 'PNG')
entries.append((256, 32, buf.getvalue()))

ico = struct.pack('<HHH', 0, 1, len(entries))
off = 6 + 16 * len(entries)
imgs = b''
for s, bits, payload in entries:
    w = s if s < 256 else 0
    ico += struct.pack('<BBBBHHII', w, w, 0, 0, 1, bits, len(payload), off)
    imgs += payload
    off += len(payload)
open('app.ico', 'wb').write(ico + imgs)
img.save('app.png')
print('ok, размеров:', len(entries))
