"""What the accounts-regress scenarios measure in a capture (a PNG of sill's sheet surface or of the output).

  pixels.py card PNG                       "X0 Y0 X1 Y1 W H": the sheet's card (the box of its fully opaque pixels) and the capture's size
  pixels.py same A B [--box X0,Y0,X1,Y1]   exit 0 when the two captures draw the same pixels (in the box)
  pixels.py ink PNG [--box ..] [--max-lum N]  "X0 Y0 X1 Y1" of the dark text pixels (luminance up to N, default 70)
  pixels.py contrast PNG --box ..          "RATIO FILL TEXT": WCAG contrast of the box's text on its fill
  pixels.py inkwidth PNG --box ..          the width of the box's ink: what differs from the box's own corner colour

The sheet's surface is transparent outside its card, so the card is found by alpha; text is found by its colour, never read.
"""
import argparse
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.array(Image.open(path).convert("RGBA")).astype(np.int32)


def crop(a, box):
    if not box:
        return a, 0, 0
    x0, y0, x1, y1 = (int(v) for v in box.split(","))
    return a[y0:y1, x0:x1], x0, y0


def lum(a):
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def channel(v):
    v = v / 255.0
    return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4


def relative(rgb):
    r, g, b = (channel(float(c)) for c in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def bbox(mask, ox=0, oy=0):
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return None
    return xs.min() + ox, ys.min() + oy, xs.max() + ox, ys.max() + oy


ap = argparse.ArgumentParser()
ap.add_argument("cmd")
ap.add_argument("png")
ap.add_argument("other", nargs="?")
ap.add_argument("--box")
ap.add_argument("--max-lum", type=float, default=70)
args = ap.parse_args()
a = load(args.png)

if args.cmd == "card":
    box = bbox(a[..., 3] == 255)
elif args.cmd == "same":
    b = load(args.other)
    if a.shape != b.shape:
        sys.exit(1)
    (ca, _, _), (cb, _, _) = crop(a, args.box), crop(b, args.box)
    differing = (np.abs(ca - cb).max(axis=-1) > 8).mean()
    print(f"{differing:.5f}")
    sys.exit(0 if differing < 0.0005 else 1)
elif args.cmd == "ink":
    c, ox, oy = crop(a, args.box)
    box = bbox((c[..., 3] == 255) & (lum(c) <= args.max_lum), ox, oy)
elif args.cmd == "inkwidth":
    c, _, _ = crop(a, args.box)
    ground = c[1, 1, :3]
    box = bbox(np.abs(c[..., :3] - ground).max(axis=-1) > 40)
    if box:
        print(box[2] - box[0] + 1)
        sys.exit(0)
elif args.cmd == "contrast":
    c, _, _ = crop(a, args.box)
    px = c.reshape(-1, 4)[:, :3]
    colours, counts = np.unique(px, axis=0, return_counts=True)
    fill = colours[counts.argmax()]
    far = max(range(len(colours)), key=lambda i: abs(relative(colours[i]) - relative(fill)))
    text = colours[far]
    hi, lo = sorted((relative(fill), relative(text)), reverse=True)
    print(f"{(hi + 0.05) / (lo + 0.05):.2f} {tuple(int(v) for v in fill)} {tuple(int(v) for v in text)}")
    sys.exit(0)
else:
    sys.exit(2)
if box is None:
    sys.exit(1)
print(*(int(v) for v in box), *((a.shape[1], a.shape[0]) if args.cmd == "card" else ()))
