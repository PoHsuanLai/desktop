#!/usr/bin/env bash
# Every unit of a trusted service, and the drop-in for the portal frontend's own unit, throws away all the loader variables.
# peephole proves a service at `Full` only when its unit's `UnsetEnvironment=` holds every name of LOADER_VARIABLES (peephole-core
# src/facts.rs), and casement and the portal backend (transom) require `Full` for the services they trust: a unit that lacks one
# name is refused at run time, so the screen cannot be shared, the shell is not trusted. The list is peephole's constant, read from
# its source here; nothing in this repository copies it by hand except the drop-in, which this check compares.
#
#   gate/check-loader-unset.sh [--peephole DIR] [--siblings DIR] [--table FILE] [--pending FILE] [--dropin FILE]...
#
#   --peephole DIR   a peephole checkout (default: $PEEPHOLE_DIR, then the repo beside this one, then ~/peephole). None: exit 2
#   --siblings DIR   the component checkouts, where the unit files are looked for under <repo>/dist, <repo>/dbus and one folder
#                    deeper (default: the parent of this repo). A unit whose file is not found is noted and skipped
#   --table FILE     the table of the desktop's programs (default dist/desktop-callers.toml): its `unit` rows are the units checked,
#                    xdg-desktop-portal.service excepted (it is the distro's; its drop-in is checked instead), plus turnstile.service
#   --pending FILE   units that wait for their own repository to carry the line (default gate/loader-unset-pending.txt: `unit
#                    repository` per line). A unit there that is already complete is a fault (take it off the list); the file is
#                    a debt list and ends empty
#   --dropin FILE    another drop-in to check (e.g. the one an installer staged); session/xdg-desktop-portal.service.d/10-quire.conf
#                    is always checked
# `UnsetEnvironment=` lines add up; an empty assignment resets the list (systemd.exec(5)); an entry NAME=value does not count.
# Exit: 0 clean, 1 a fault (each printed), 2 usage or no peephole.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
table="$ROOT/dist/desktop-callers.toml" peephole="" siblings="$(dirname "$ROOT")" pending="$HERE/loader-unset-pending.txt"
dropins=("$ROOT/session/xdg-desktop-portal.service.d/10-quire.conf")
while [ $# -gt 0 ]; do
  case "$1" in
    --peephole) peephole=${2:?}; shift ;;
    --siblings) siblings=${2:?}; shift ;;
    --table) table=${2:?}; shift ;;
    --pending) pending=${2:?}; shift ;;
    --dropin) dropins+=("${2:?}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
command -v python3 >/dev/null || { echo "check-loader-unset: python3 is not installed" >&2; exit 2; }
if [ -z "$peephole" ]; then
  for d in "${PEEPHOLE_DIR:-}" "$ROOT/../peephole" "$HOME/peephole"; do
    if [ -n "$d" ] && [ -f "$d/peephole-core/src/facts.rs" ]; then peephole=$d; break; fi
  done
fi
if [ -z "$peephole" ] || [ ! -f "$peephole/peephole-core/src/facts.rs" ]; then
  echo "check-loader-unset: no peephole checkout (peephole-core/src/facts.rs): give --peephole DIR or set PEEPHOLE_DIR" >&2
  exit 2
fi
exec python3 -I - "$peephole/peephole-core/src/facts.rs" "$table" "$siblings" "$pending" "${dropins[@]}" <<'PY'
import os
import re
import sys
import tomllib

facts, table, siblings, pending_file, *dropins = sys.argv[1:]
src = open(facts, encoding="utf-8").read()
m = re.search(r"pub const LOADER_VARIABLES: \[&str; (\d+)\] = \[(.*?)\];", src, re.S)
if not m:
    sys.exit("check-loader-unset: LOADER_VARIABLES not found in " + facts)
wanted = re.findall(r'"([^"]+)"', m.group(2))
if len(wanted) != int(m.group(1)) or not wanted:
    sys.exit("check-loader-unset: could not read the list from " + facts)


def unset_of(path):
    names = set()
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line.startswith("UnsetEnvironment="):
            rest = line[len("UnsetEnvironment="):].strip()
            if not rest:
                names = set()
            names.update(rest.split())
    return names


def missing_of(path):
    have = unset_of(path)
    return [n for n in wanted if n not in have]


faults, notes = [], []
pending = {}
if os.path.exists(pending_file):
    for line in open(pending_file, encoding="utf-8"):
        line = line.split("#")[0].split()
        if line:
            pending[line[0]] = line[1] if len(line) > 1 else "?"

units = []
with open(table, "rb") as f:
    for peer in tomllib.load(f).get("peer", []):
        u = peer.get("unit")
        if u and u != "xdg-desktop-portal.service" and u not in units:
            units.append(u)
if "turnstile.service" not in units:
    units.append("turnstile.service")  # the input service is not a table row but root runs it and keycap trusts the socket

found = {}
for repo in sorted(os.listdir(siblings)):
    base = os.path.join(siblings, repo)
    if not os.path.isdir(base):
        continue
    for sub in ("dist", "dbus", os.path.join("dist", "systemd")):
        d = os.path.join(base, sub)
        if os.path.isdir(d):
            for name in os.listdir(d):
                if name.endswith(".service") and os.path.isfile(os.path.join(d, name)):
                    found.setdefault(name, os.path.join(d, name))

for u in units:
    path = found.get(u)
    if path is None:
        notes.append(f"{u}: no unit file found beside this repository; skipped")
        continue
    miss = missing_of(path)
    if miss and u in pending:
        notes.append(f"{u}: waits for {pending[u]} (still missing {len(miss)}): {path}")
    elif miss:
        faults.append(f"{u} ({path}) does not unset: {' '.join(miss)}")
    elif u in pending:
        faults.append(f"{u} is complete: take it off {pending_file}")
for u in pending:
    if u not in units:
        faults.append(f"{u} is on {pending_file} but is not a unit this check looks at")

for d in dropins:
    if not os.path.isfile(d):
        faults.append(f"{d}: no such drop-in")
        continue
    miss = missing_of(d)
    if miss:
        faults.append(f"{d} does not unset: {' '.join(miss)}")
    elif not re.search(r"^\[Service\]\s*$", open(d, encoding="utf-8").read(), re.M):
        faults.append(f"{d}: no [Service] section")

for n in notes:
    print(f"check-loader-unset: note: {n}")
for f in faults:
    print(f"check-loader-unset: {f}", file=sys.stderr)
if not faults:
    print(f"check-loader-unset: ok ({len(wanted)} variables; {len(units)} units, {len(dropins)} drop-in(s))")
sys.exit(1 if faults else 0)
PY
