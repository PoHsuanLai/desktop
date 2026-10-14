#!/usr/bin/env bash
# check-legacy-free.sh against generated trees: a clean one passes, one with an offending file fails.
#   legacy-free-selftest.sh
# Exit 0 pass, 1 a check failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
fail() { echo "legacy-free-selftest: $*" >&2; exit 1; }
word="c""osmic"   # split: the fixture is made here, not committed

for kind in clean offending; do
  mkdir -p "$tmp/$kind/sill/src"
  echo 'fn main() {}' >"$tmp/$kind/sill/src/main.rs"
done
printf '// uses the %s-comp protocol\n' "$word" >>"$tmp/offending/sill/src/main.rs"
for kind in clean offending; do git -C "$tmp/$kind/sill" init -q || fail "git init"; done

rc=0; "$HERE/check-legacy-free.sh" "$tmp/clean" >"$tmp/clean.out" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$tmp/clean.out"; fail "the clean tree must pass (exit $rc)"; }
rc=0; "$HERE/check-legacy-free.sh" "$tmp/offending" >"$tmp/bad.out" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$tmp/bad.out"; fail "the offending tree must fail with 1 (exit $rc)"; }
grep -q 'sill:src/main.rs' "$tmp/bad.out" || { cat "$tmp/bad.out"; fail "the offending file is not named"; }
echo "legacy-free-selftest: ok"
