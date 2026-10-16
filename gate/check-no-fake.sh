#!/usr/bin/env bash
# No stand-in ships. Several crates (turnstile, peephole, keycap, palmrest) carry a `fake` feature: a fake kernel, a
# made-up caller identity. It exists for tests, and a program built with it would let anything pass as anyone, so no
# command that builds what the desktop ships may switch it on. Three places are read:
#
#   1. the scripts and workflows that build or install the desktop (install.sh, install/, release/, gate/ is left out, the
#      workflows): no line that runs cargo (or this repo's cargo helpers) names `fake` or asks for `--all-features`;
#   2. manifest.toml: it selects revs and test arguments only; any other key that could choose features, or `fake` in a
#      key other than the test arguments (`gate_args`, `gate_extra`), fails;
#   3. every Cargo.toml of the component checkouts (--siblings): `fake` is not in a crate's default features (followed
#      through the features that name it) and no normal or build dependency, or workspace dependency, turns it on. A
#      dev-dependency may: tests need it, and cargo does not unify it into a build of the package itself.
#
#   gate/check-no-fake.sh [--siblings DIR] [--no-crates]
#
#   --siblings DIR  the component checkouts side by side (default: the parent of this repo); a missing one is skipped
#   --no-crates     read only 1 and 2 (for a tree without the checkouts)
# Exit: 0 clean, 1 something found (each printed), 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
siblings="$(dirname "$ROOT")" crates=1
while [ $# -gt 0 ]; do
  case "$1" in
    --siblings) siblings=${2:?}; shift ;;
    --no-crates) crates=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
command -v python3 >/dev/null || { echo "check-no-fake: python3 is not installed" >&2; exit 2; }
exec python3 -I - "$ROOT" "$siblings" "$crates" <<'PY'
import os
import re
import subprocess
import sys
import tomllib

root, siblings, crates = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
found = []


def bad(message):
    found.append(message)


# 1. The build and install scripts and workflows.
RUNS_CARGO = re.compile(r"\bcargo(_in)?\b|\bbuild_outside\b|\bcargo-[a-z]+\b")
NAMES_FAKE = re.compile(r"\bfake\b|--all-features")
scripts = [os.path.join(root, "install.sh")]
for folder in ("install", "release", ".github/workflows", "harness"):
    for dirpath, _, files in os.walk(os.path.join(root, folder)):
        for name in sorted(files):
            if name.endswith((".sh", ".yml", ".yaml", ".py")):
                scripts.append(os.path.join(dirpath, name))
for path in scripts:
    if not os.path.isfile(path):
        continue
    # The release's own self-test packs a made-up release: its word "fake" is not a cargo feature.
    if os.path.basename(path) in ("selftest.sh", "selftest-forge.py", "health-scenarios.sh"):
        continue
    with open(path, encoding="utf-8", errors="replace") as f:
        for number, line in enumerate(f, 1):
            code = line.split("#", 1)[0]
            if RUNS_CARGO.search(code) and NAMES_FAKE.search(code):
                bad(f"{os.path.relpath(path, root)}:{number}: a build command names the fake feature or all features: {line.strip()}")

# 2. The manifest.
TEST_KEYS = {"gate_args", "gate_extra"}
KNOWN_KEYS = {"url", "rev", "branch", "gate"} | TEST_KEYS
with open(os.path.join(root, "manifest.toml"), "rb") as f:
    manifest = tomllib.load(f)
for repo, table in sorted(manifest.get("repo", {}).items()):
    for key, value in table.items():
        if key not in KNOWN_KEYS:
            bad(f"manifest.toml: [repo.{repo}] has the key {key!r}, which the desktop does not know; a key that selects features would ship them")
        elif key not in TEST_KEYS and re.search(r"\bfake\b", str(value)):
            bad(f"manifest.toml: [repo.{repo}] {key} names fake")


# 3. The crates.
def reaches_fake(features, start="default", seen=None):
    seen = set() if seen is None else seen
    if start in seen:
        return False
    seen.add(start)
    for item in features.get(start, []):
        name = item.split("/")[-1].removeprefix("dep:")
        if name == "fake" and ("/" in item or item == "fake"):
            return True
        if item in features and reaches_fake(features, item, seen):
            return True
    return False


def turns_on(spec):
    return isinstance(spec, dict) and "fake" in spec.get("features", [])


def check_manifest(path, label):
    with open(path, "rb") as f:
        doc = tomllib.load(f)
    features = doc.get("features", {})
    if reaches_fake(features):
        bad(f"{label}: `fake` is in the default features")
    tables = [("dependencies", doc.get("dependencies", {})), ("build-dependencies", doc.get("build-dependencies", {})),
              ("workspace.dependencies", doc.get("workspace", {}).get("dependencies", {}))]
    for target in doc.get("target", {}).values():
        tables.append(("target dependencies", target.get("dependencies", {})))
    for kind, table in tables:
        for name, spec in table.items():
            if turns_on(spec):
                bad(f"{label}: the {kind} entry {name} turns `fake` on")


if crates and os.path.isdir(siblings):
    for repo in sorted(os.listdir(siblings)):
        repo_dir = os.path.join(siblings, repo)
        if not os.path.isdir(os.path.join(repo_dir, ".git")) and not os.path.isfile(os.path.join(repo_dir, ".git")):
            continue
        listing = subprocess.run(["git", "-C", repo_dir, "ls-files", "--cached", "--others", "--exclude-standard", "--", "Cargo.toml", "**/Cargo.toml"],
                                 capture_output=True, text=True)
        if listing.returncode != 0:
            bad(f"{repo}: cannot list its files ({listing.stderr.strip()}); its crates were not read")
            continue
        for rel in sorted(set(listing.stdout.split())):
            try:
                check_manifest(os.path.join(repo_dir, rel), f"{repo}/{rel}")
            except (OSError, tomllib.TOMLDecodeError) as e:
                bad(f"{repo}/{rel}: cannot be read: {e}")

if found:
    for line in found:
        print(f"check-no-fake: {line}")
    print(f"check-no-fake: FAIL ({len(found)})")
    sys.exit(1)
print("check-no-fake: ok (no shipped build command, manifest key or crate turns the fake feature on)")
PY
