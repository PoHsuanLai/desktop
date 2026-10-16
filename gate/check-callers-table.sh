#!/usr/bin/env bash
# The table of the desktop's own programs (dist/desktop-callers.toml, installed as /etc/quire/desktop-callers.toml)
# is complete and well formed. It is read by the update service, the portal backend and the input service, and each
# refuses every caller when a row it needs is missing, so a hole here is a desktop that cannot update or share a screen.
#
#   gate/check-callers-table.sh [--table FILE] [--peephole DIR] [--siblings DIR]
#
#   --table FILE     the table (default dist/desktop-callers.toml of this repo)
#   --peephole DIR   a peephole checkout: its peephole-core/src/roles.rs lists the roles (default: $PEEPHOLE_DIR, then the
#                    repo beside this one, then ~/peephole). Without one the check cannot say which roles are missing: exit 2
#   --siblings DIR   the component checkouts, to compare each unit's ExecStart program with the row's `exe` list
#                    (default: the parent of this repo; a unit whose file is not found there is noted and skipped)
#
# Checks: the file parses; every key is one the reader knows; every row has an app, a role and a non-empty list of
# `exe` paths, each absolute, without `..`, without `**` and with at most one `*` per path segment; no unit twice;
# no row without a unit except for the roles that are programs (settings, updater_cli, sandbox_launcher, manager), and
# `settings` has one (the update service asks for it at the image level); every role of peephole's list has a row
# and every row is one of those roles; and each unit's ExecStart program, where its file is in a checkout, matches
# one of its row's paths.
# Exit: 0 clean, 1 something is wrong (each problem printed), 2 usage or nothing to compare the roles with.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
table="$ROOT/dist/desktop-callers.toml" peephole="" siblings="$(dirname "$ROOT")"
while [ $# -gt 0 ]; do
  case "$1" in
    --table) table=${2:?}; shift ;;
    --peephole) peephole=${2:?}; shift ;;
    --siblings) siblings=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
command -v python3 >/dev/null || { echo "check-callers-table: python3 is not installed" >&2; exit 2; }
[ -f "$table" ] || { echo "check-callers-table: no table at $table" >&2; exit 2; }
if [ -z "$peephole" ]; then
  for d in "${PEEPHOLE_DIR:-}" "$ROOT/../peephole" "$HOME/peephole"; do
    if [ -n "$d" ] && [ -f "$d/peephole-core/src/roles.rs" ]; then peephole=$d; break; fi
  done
fi
if [ -z "$peephole" ] || [ ! -f "$peephole/peephole-core/src/roles.rs" ]; then
  echo "check-callers-table: no peephole checkout (peephole-core/src/roles.rs): give --peephole DIR or set PEEPHOLE_DIR" >&2
  exit 2
fi
exec python3 -I - "$table" "$peephole/peephole-core/src/roles.rs" "$siblings" <<'PY'
import fnmatch
import os
import re
import sys
import tomllib

table_path, roles_path, siblings = sys.argv[1:4]
problems = []


def bad(message):
    problems.append(message)


# The roles: the constants of roles.rs, in the order of its `ALL` list.
text = open(roles_path, encoding="utf-8").read()
consts = dict(re.findall(r'pub const ([A-Z_]+): RoleName = RoleName::from_static\("([a-z0-9_]+)"\);', text))
all_match = re.search(r"pub const ALL: \[RoleName; (\d+)\] = \[(.*?)\];", text, re.S)
if not all_match:
    print("check-callers-table: roles.rs has no ALL list", file=sys.stderr)
    sys.exit(2)
names = re.findall(r"[A-Z][A-Z_]+", all_match.group(2))
unknown = [n for n in names if n not in consts]
if unknown or len(names) != int(all_match.group(1)):
    print(f"check-callers-table: cannot read roles.rs ALL list ({names}, declared {all_match.group(1)})", file=sys.stderr)
    sys.exit(2)
roles = [consts[n] for n in names]

# Programs known by their image alone, as opposed to services.
UNITLESS = {"settings", "updater_cli", "sandbox_launcher", "manager"}
KEYS = {"app", "unit", "exe", "role", "name"}
ROW_MAX = 256

try:
    with open(table_path, "rb") as f:
        data = tomllib.load(f)
except (OSError, tomllib.TOMLDecodeError) as e:
    print(f"check-callers-table: {table_path}: {e}")
    sys.exit(1)

extra_top = sorted(set(data) - {"peer"})
if extra_top:
    bad(f"unknown top-level key(s) {extra_top}: only [[peer]] rows are read")
rows = data.get("peer", [])
if not rows:
    bad("the table has no [[peer]] rows")
if len(rows) > ROW_MAX:
    bad(f"{len(rows)} rows; the reader takes at most {ROW_MAX}")


def valid_exe(path):
    if not isinstance(path, str) or not path.startswith("/"):
        return "is not an absolute path"
    segments = path.split("/")[1:]
    if any(s in ("", ".", "..") for s in segments):
        return "has an empty, . or .. segment"
    if any("**" in s or s.count("*") > 1 for s in segments):
        return "has ** or more than one * in a segment"
    return None


seen_units = {}
by_role = {}
for i, row in enumerate(rows, 1):
    who = f"row {i} ({row.get('app', '?')}, {row.get('role', '?')})"
    stray = sorted(set(row) - KEYS)
    if stray:
        bad(f"{who}: unknown key(s) {stray}")
    for key in ("app", "role"):
        if not isinstance(row.get(key), str) or not row.get(key):
            bad(f"{who}: no {key}")
    exe = row.get("exe")
    if not isinstance(exe, list) or not exe:
        bad(f"{who}: `exe` must be a non-empty list")
        exe = []
    for path in exe:
        why = valid_exe(path)
        if why:
            bad(f"{who}: exe {path!r} {why}")
    if len(set(exe)) != len(exe):
        bad(f"{who}: the same exe path twice")
    role = row.get("role")
    unit = row.get("unit")
    if role not in roles:
        bad(f"{who}: {role!r} is not a role of peephole's list")
    if unit is None:
        if role not in UNITLESS:
            bad(f"{who}: no unit, and {role!r} is a service (only {sorted(UNITLESS)} are known by their image alone)")
    else:
        if not isinstance(unit, str) or not unit.endswith(".service"):
            bad(f"{who}: unit {unit!r} is not a .service")
        elif unit in seen_units:
            bad(f"{who}: unit {unit} is also in row {seen_units[unit]} (the reader refuses a unit twice)")
        else:
            seen_units[unit] = i
    by_role.setdefault(role, []).append(row)

for role in roles:
    if role not in by_role:
        bad(f"no row for the role {role}")
    elif role in UNITLESS and role == "settings" and not any("unit" not in r for r in by_role[role]):
        bad("settings has no row without a unit: Settings started by a launcher would not be known to the update service")
    elif role not in UNITLESS and len(by_role[role]) != 1:
        bad(f"the role {role} has {len(by_role[role])} rows; services have one")

# Each unit's ExecStart program, where the unit's file is in a checkout, must be one of its row's paths.
def segment_glob(pattern, path):
    p, q = pattern.split("/"), path.split("/")
    return len(p) == len(q) and all(fnmatch.fnmatchcase(b, a) for a, b in zip(p, q))


unit_files = {}
if os.path.isdir(siblings):
    for repo in sorted(os.listdir(siblings)):
        for sub in ("dist", "dbus", "dist/systemd"):
            d = os.path.join(siblings, repo, sub)
            if os.path.isdir(d):
                for name in sorted(os.listdir(d)):
                    if name.endswith(".service"):
                        unit_files.setdefault(name, os.path.join(d, name))
checked = skipped = 0
for row in rows:
    unit = row.get("unit")
    if not unit:
        continue
    path = unit_files.get(unit)
    if path is None:
        skipped += 1
        continue
    start = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("ExecStart="):
                words = line[len("ExecStart="):].split()
                start = words[0].lstrip("-@+!:") if words else None
                break
    if start is None:
        bad(f"{unit} ({path}): no ExecStart")
    elif not any(segment_glob(p, start) for p in row.get("exe", [])):
        bad(f"{unit}: ExecStart {start} (in {path}) is none of its row's exe paths")
    else:
        checked += 1

if problems:
    for p in problems:
        print(f"check-callers-table: {p}")
    print(f"check-callers-table: FAIL ({len(problems)} problem(s))")
    sys.exit(1)
print(f"check-callers-table: ok ({len(rows)} rows, {len(roles)} roles; {checked} unit(s) compared with their files, {skipped} not found in {siblings})")
PY
