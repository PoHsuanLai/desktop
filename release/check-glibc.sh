#!/usr/bin/env bash
# Fail if a binary in the stage needs a newer C library than the oldest computer the desktop supports (Ubuntu
# 24.04: glibc 2.39, libstdc++ from GCC 13). Reads the undefined symbols of every ELF file (`objdump -T`) and
# compares the symbol versions they ask for.
#
#   release/check-glibc.sh [MAX] [--stage DIR] [--glibcxx MAX] [--cxxabi MAX]
#
#   MAX            the newest GLIBC_x.y allowed (default 2.39)
#   --stage DIR    the tree to scan (default build/release/stage under this repo); every ELF file in it
#   --glibcxx MAX  the newest GLIBCXX_x.y.z allowed (default 3.4.32, GCC 13)
#   --cxxabi MAX   the newest CXXABI_x.y.z allowed (default 1.3.14, GCC 13)
#
# Prints each offending file, symbol and version. Needs objdump (binutils).
# Exit: 0 all within the limits, 1 something is too new, 2 bad usage or objdump missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
max_glibc=2.39 max_glibcxx=3.4.32 max_cxxabi=1.3.14 stage="$HERE/../build/release/stage"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage=${2:?}; shift ;;
    --glibcxx) max_glibcxx=${2:?}; shift ;;
    --cxxabi) max_cxxabi=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) max_glibc=$1 ;;
  esac
  shift
done
command -v objdump >/dev/null || { echo "check-glibc.sh: objdump is not installed (binutils)" >&2; exit 2; }
[ -d "$stage" ] || { echo "check-glibc.sh: no folder $stage" >&2; usage >&2; exit 2; }
stage=$(cd "$stage" && pwd -P)

is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; }
# newer VERSION MAX: true when VERSION is a later version than MAX.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }
limit() { case "$1" in GLIBC) echo "$max_glibc" ;; GLIBCXX) echo "$max_glibcxx" ;; CXXABI) echo "$max_cxxabi" ;; esac; }

bad=0 scanned=0
while IFS= read -r -d '' file; do
  is_elf "$file" || continue
  scanned=$((scanned + 1))
  # One "FAMILY VERSION SYMBOL" line per undefined symbol that carries a GLIBC_, GLIBCXX_ or CXXABI_ version.
  while read -r family version symbol; do
    if newer "$version" "$(limit "$family")"; then
      echo "check-glibc: ${file#"$stage"/}: $symbol needs ${family}_$version (allowed up to $(limit "$family"))" >&2
      bad=1
    fi
  done < <(objdump -T "$file" 2>/dev/null | awk '
    /\*UND\*/ {
      for (i = 1; i <= NF; i++) {
        if (match($i, /^\(?(GLIBCXX|GLIBC|CXXABI)_[0-9][0-9.]*\)?$/)) {
          v = $i; gsub(/[()]/, "", v); n = index(v, "_")
          print substr(v, 1, n - 1), substr(v, n + 1), $NF
        }
      }
    }' | sort -u)
done < <(find "$stage" -type f -print0)
[ "$scanned" -gt 0 ] || { echo "check-glibc: no binaries under $stage" >&2; exit 2; }
if [ "$bad" = 0 ]; then
  echo "check-glibc: $scanned binaries need at most GLIBC_$max_glibc, GLIBCXX_$max_glibcxx, CXXABI_$max_cxxabi"
fi
exit "$bad"
