"""Reads the accounts sheet's traffic out of the recorded bus (busctl monitor --json=short).

  sheet-bus.py BUS.JSONL [--from N] [--count]    one line per message: INDEX KIND JSON

KIND is open, update or close (accountd to sill: the SheetView the sheet draws) or input (sill to accountd: what the
person did). INDEX counts those messages from 0; a scenario remembers --count before an action and reads `--from`
that after it, so a check sees only what the action caused.
"""
import argparse
import json
import sys

ap = argparse.ArgumentParser()
ap.add_argument("bus")
ap.add_argument("--from", dest="start", type=int, default=0)
ap.add_argument("--count", action="store_true")
args = ap.parse_args()

rows = []
try:
    lines = open(args.bus, errors="replace").read().splitlines()
except OSError:
    lines = []
for line in lines:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("interface") != "org.quire.AccountsSheet1" or m.get("type") not in ("method_call", "signal"):
        continue
    member = m.get("member")
    data = m.get("payload", {}).get("data", [])
    if member in ("Open", "Update") and len(data) >= 2:
        rows.append((member.lower(), data[-1]))
    elif member == "Close":
        rows.append(("close", "{}"))
    elif member == "Input" and len(data) >= 2:
        rows.append(("input", data[1]))
if args.count:
    print(len(rows))
else:
    for i, (kind, body) in enumerate(rows):
        if i >= args.start:
            print(i, kind, body)
