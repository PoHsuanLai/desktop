#!/usr/bin/env bash
# Nothing the desktop ships lets the person, or a group, open /dev/uinput. A program that can make input devices can type
# into any window, past every question the desktop asks, so the node belongs to root and one service (turnstile) makes the
# devices for the two programs that need them. This reads what is shipped and fails on:
#
#   - a device rule that mentions uinput and is not exactly "root, 0600, and no `uaccess` tag" (a rule may remove the tag
#     with TAG-=; it may not add it);
#   - a service that lets itself open the node (`DeviceAllow=/dev/uinput`) other than turnstile.service, or a drop-in for
#     any service that does (keycap's stand-alone `keycap.uinput.conf` / `10-uinput.conf`);
#   - an install or release script that places keycap's stand-alone pieces (`70-keycap.rules`, `keycap.uinput.conf`,
#     `10-uinput.conf`, `keycap-modules.conf`, `palmrest-modules.conf`), which only a machine without the input service needs.
#
#   gate/check-no-uinput-access.sh [--siblings DIR] [--stage DIR]...
#
#   --siblings DIR  the component checkouts: the rule and service files the scripts name (`dist/<file>`) are read from
#                   turnstile, keycap, palmrest and sill there (default: the parent of this repo)
#   --stage DIR     also read a staged tree (a release stage/, or an installer's --destdir): every *.rules, *.service and
#                   *.service.d/*.conf in it. May be given more than once.
# Not a proof: it reads rule text, it does not run udev. A rule that reaches the node without naming it is not seen.
# Exit: 0 clean, 1 something found (each printed), 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
siblings="$(dirname "$ROOT")" stages=()
while [ $# -gt 0 ]; do
  case "$1" in
    --siblings) siblings=${2:?}; shift ;;
    --stage) stages+=("${2:?}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
command -v python3 >/dev/null || { echo "check-no-uinput-access: python3 is not installed" >&2; exit 2; }
exec python3 -I - "$ROOT" "$siblings" "${stages[@]}" <<'PY'
import os
import re
import sys

root, siblings, stages = sys.argv[1], sys.argv[2], sys.argv[3:]
found = []
looked = 0


def bad(message):
    found.append(message)


def code_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for number, line in enumerate(f, 1):
            text = line.strip()
            if text and not text.startswith("#") and not text.startswith("//"):
                yield number, text


def check_rule(path, label):
    for number, text in code_lines(path):
        if "uinput" not in text:
            continue
        adds_tag = re.search(r'TAG\s*\+?=\s*"[^"]*uaccess', text) or re.search(r'ENV\{[^}]*\}\s*=.*uaccess', text)
        if adds_tag:
            bad(f"{label}:{number}: a rule on uinput gives the person the node (uaccess): {text}")
        if not re.search(r'MODE\s*=\s*"0?600"', text):
            bad(f"{label}:{number}: a rule on uinput does not set MODE=\"0600\": {text}")
        if not re.search(r'GROUP\s*=\s*"root"', text):
            bad(f"{label}:{number}: a rule on uinput does not set GROUP=\"root\": {text}")


def check_unit(path, label, broker):
    for number, text in code_lines(path):
        if re.match(r"DeviceAllow\s*=\s*/dev/uinput", text) and not broker:
            bad(f"{label}:{number}: a service other than the input service may open /dev/uinput: {text}")


def check_file(path, label):
    global looked
    name = os.path.basename(path)
    parent = os.path.basename(os.path.dirname(path))
    looked += 1
    if name.endswith(".rules"):
        check_rule(path, label)
    elif name.endswith(".service") or parent.endswith(".service.d"):
        check_unit(path, label, broker=(name == "turnstile.service"))
        if parent.endswith(".service.d"):
            for number, text in code_lines(path):
                if "uinput" in text:
                    bad(f"{label}:{number}: a drop-in mentions uinput: {text}")


# 1. The files the build and install scripts name.
scripts = [os.path.join(root, "release", "build.sh"), os.path.join(root, "install.sh")]
scripts += [os.path.join(root, "install", n) for n in sorted(os.listdir(os.path.join(root, "install"))) if n.endswith(".sh")]
STANDALONE = ("70-keycap.rules", "keycap.uinput.conf", "10-uinput.conf", "keycap-modules.conf", "palmrest-modules.conf")
PLACES = re.compile(r"\bput(_system)?\b|\binstall\s|\bcp\s|^echo \"[0-9]{3} ")
named = set()
for path in scripts:
    if not os.path.isfile(path):
        continue
    for number, text in code_lines(path):
        # a line that tests for a file or prints a warning about one is not a line that places it
        if PLACES.search(text) and not text.lstrip().startswith(("note ", "if ", "[")):
            for name in STANDALONE:
                if name in text:
                    bad(f"{os.path.relpath(path, root)}:{number}: places {name}, which only a machine without the input service needs: {text}")
        for match in re.finditer(r"dist/([A-Za-z0-9._-]+\.(?:rules|service))", text):
            named.add(match.group(1))
for name in sorted(named):
    where = [os.path.join(siblings, repo, "dist", name) for repo in ("turnstile", "keycap", "palmrest", "sill")] + [os.path.join(root, "dist", name)]
    for path in where:
        if os.path.isfile(path):
            check_file(path, os.path.relpath(path, siblings) if path.startswith(siblings) else os.path.relpath(path, root))

# 2. Staged trees.
for stage in stages:
    if not os.path.isdir(stage):
        print(f"check-no-uinput-access: no such directory {stage}", file=sys.stderr)
        sys.exit(2)
    for dirpath, _, files in os.walk(stage):
        for name in sorted(files):
            path = os.path.join(dirpath, name)
            parent = os.path.basename(dirpath)
            if name.endswith((".rules", ".service")) or parent.endswith(".service.d"):
                check_file(path, os.path.relpath(path, stage))
            if name in STANDALONE and name != "keycap-modules.conf" and name != "palmrest-modules.conf":
                bad(f"{os.path.relpath(path, stage)}: a stand-alone piece of keycap is in what is shipped")

if found:
    for line in found:
        print(f"check-no-uinput-access: {line}")
    print(f"check-no-uinput-access: FAIL ({len(found)})")
    sys.exit(1)
print(f"check-no-uinput-access: ok ({looked} rule or service file(s) read; nothing opens /dev/uinput to the person or a group)")
PY
