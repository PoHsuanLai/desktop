"""Finds a control in the files quire's debug probe wrote (QUIRE_DEBUG_PROBE, ds-blitz `debug-probe`).

  probe-find.py DIR PID ROLE NAME [--nth N] [--window W] [--state]

Each window of process PID writes DIR/PID-W.tsv, one control per line: role, x, y, w, h, state, name (tab
separated; the box is the border box in the window's logical pixels from its top-left corner). Prints
"CX CY" (the box's centre, rounded) of the first control with exactly this role and name (the Nth with --nth,
counted from 1; negative counts from the end, -1 the last), or with --state its state words. Exit 1 when there is none, so a poll can wait for one.
"""
import argparse
import sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("pid")
ap.add_argument("role")
ap.add_argument("name")
ap.add_argument("--nth", type=int, default=1)
ap.add_argument("--window", default="0")
ap.add_argument("--state", action="store_true")
args = ap.parse_args()

try:
    text = (Path(args.dir) / f"{args.pid}-{args.window}.tsv").read_text()
except OSError:
    sys.exit(1)

found = []
for line in text.splitlines():
    cols = line.split("\t")
    if len(cols) == 7 and cols[0] == args.role and cols[6] == args.name:
        found.append(cols)
index = args.nth - 1 if args.nth > 0 else args.nth
if args.nth == 0 or not -len(found) <= index < len(found):
    sys.exit(1)
cols = found[index]
if args.state:
    print(cols[5])
else:
    x, y, w, h = (float(c) for c in cols[1:5])
    print(round(x + w / 2), round(y + h / 2))
