#!/usr/bin/env bash
# Fail if a binary in the tree needs a shared library this computer does not have. Runs `ldd` on every ELF file
# and looks for "not found". Run it where the desktop will run (a clean Ubuntu, Fedora or Arch with the runtime
# packages release/deps.sh lists) and on the build machine after the build.
#
#   release/check-ldd.sh [--stage DIR] [--ignore REGEX]
#
#   --stage DIR     the tree to scan (default build/release/stage under this repo, or give an installed
#                   /opt/quire/current); libraries in DIR/opt/quire/current/lib, DIR/lib and DIR/lib64
#                   are found as the installed program would find them
#   --ignore REGEX  a library name (extended regex) that may be missing, for one that is loaded on demand
#
# ldd starts the program's loader, so run it only on trees you built. Libraries opened later with dlopen
# are not seen by ldd at all.
# Exit: 0 everything resolves, 1 a library is missing, 2 bad usage or ldd missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stage="$HERE/../build/release/stage" ignore=""
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage=${2:?}; shift ;;
    --ignore) ignore=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
command -v ldd >/dev/null || { echo "check-ldd.sh: ldd is not installed" >&2; exit 2; }
[ -d "$stage" ] || { echo "check-ldd.sh: no folder $stage" >&2; usage >&2; exit 2; }
stage=$(cd "$stage" && pwd -P)

libs=""
for d in "$stage/opt/quire/current/lib" "$stage/opt/quire/current/lib64" "$stage/lib" "$stage/lib64"; do
  [ ! -d "$d" ] || libs="$libs:$d"
done
export LD_LIBRARY_PATH="${libs#:}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; }
bad=0 scanned=0
while IFS= read -r -d '' file; do
  is_elf "$file" || continue
  scanned=$((scanned + 1))
  # "not a dynamic executable" (a static binary) prints on stderr and is fine.
  missing=$(ldd "$file" 2>/dev/null | sed -n 's/^[[:space:]]*\(.*\) => not found.*/\1/p' || true)
  [ -z "$ignore" ] || missing=$(printf '%s\n' "$missing" | grep -Ev -- "$ignore" || true)
  while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    echo "check-ldd: ${file#"$stage"/}: $lib not found" >&2
    bad=1
  done <<<"$missing"
done < <(find "$stage" -type f -print0)
[ "$scanned" -gt 0 ] || { echo "check-ldd: no binaries under $stage" >&2; exit 2; }
[ "$bad" != 0 ] || echo "check-ldd: $scanned binaries, every library resolves"
exit "$bad"
