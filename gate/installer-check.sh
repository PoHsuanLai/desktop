#!/usr/bin/env bash
# The top-level installer against stub component installers in a scratch directory: the dry run prints the plan in
# order and runs nothing, a real run passes the prefix and the staging root through, a failing component stops the run
# with a message naming it, and nothing writes outside the scratch directory (HOME is the scratch one) or calls sudo.
#
#   installer-check.sh
# Exit 0 pass, 1 a check failed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/../install.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
sib="$tmp/sib" dest="$tmp/dest" log="$tmp/calls.log" home="$tmp/home"
mkdir -p "$home" "$tmp/bin"
: >"$log"

# Stubs: each installer records its name, arguments and the variables it is given.
stub() { # REPO-RELATIVE-SCRIPT FAIL-NAME
  local f="$sib/$1"
  mkdir -p "$(dirname "$f")"
  cat >"$f" <<STUB
#!/usr/bin/env bash
echo "$1 \$* PREFIX=\${PREFIX:-} DESTDIR=\${DESTDIR:-} MAILO_PREFIX=\${MAILO_PREFIX:-}" >>"$log"
[ "\${STUB_FAIL:-}" != "$2" ] || exit 7
STUB
  chmod +x "$f"
}
stub porter/scripts/install.sh porter
stub detent/scripts/install.sh detent
stub sill/dist/install.sh sill
stub transom/scripts/install.sh transom
stub keycap/install.sh keycap
stub anyview/dist/install.sh anyview
stub mailo/dist/install.sh mailo
stub palmrest/install.sh palmrest
mkdir -p "$sib/detent/target/release"; : >"$sib/detent/target/release/detent"; chmod +x "$sib/detent/target/release/detent"
# A sudo that fails the check when called.
printf '#!/bin/sh\necho sudo >>"%s"\nexit 1\n' "$log" >"$tmp/bin/sudo"; chmod +x "$tmp/bin/sudo"
export PATH="$tmp/bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config"

fail() { echo "installer-check: $*" >&2; exit 1; }
inst() { env -u PREFIX -u DESTDIR -u SYSCONFDIR "$INSTALL" --siblings "$sib" "$@"; }

# 1. dry run: the plan, in order, nothing run.
plan=$(inst --dry-run --destdir "$dest") || fail "dry run failed"
[ ! -s "$log" ] || fail "the dry run ran an installer: $(cat "$log")"
order=$(printf '%s\n' "$plan" | grep -E '^[0-9]+\.' | awk '{print $2}' | tr '\n' ' ')
[ "$order" = "porter detent sill transom keycap anyview mailo palmrest " ] || fail "plan order is: $order"
printf '%s\n' "$plan" | grep -q 'sill .*yourself' || fail "sill is not left to the person"
printf '%s\n' "$plan" | grep -q 'palmrest .*yourself' || fail "palmrest is not left to the person"

# 2. a system prefix without root is left to the person, not attempted.
plan=$(inst --dry-run --prefix /usr) || fail "system prefix dry run failed"
printf '%s\n' "$plan" | grep -q 'porter .*yourself (needs root' || fail "a system prefix was not reported as needing root"

# 3. a real run into a staging root passes PREFIX and DESTDIR through, runs the stageable ones, never sudo.
inst --destdir "$dest" --prefix /opt/d >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; fail "staged run failed"; }
grep -q "^porter/scripts/install.sh --prefix /opt/d --sysconfdir /etc --destdir $dest" "$log" || fail "porter did not get the prefix and destdir: $(cat "$log")"
grep -q "^detent/scripts/install.sh  PREFIX=/opt/d DESTDIR=$dest" "$log" || fail "detent did not get PREFIX and DESTDIR"
grep -q "^transom/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "transom did not get the prefix and destdir"
grep -q "MAILO_PREFIX=$dest/opt/d" "$log" || fail "mailo did not get its prefix"
grep -q "^keycap/install.sh" "$log" || fail "no component ran"
! grep -q sudo "$log" || fail "sudo was called"
[ ! -e "$home/.config" ] || fail "something wrote the scratch ~/.config"
grep -q 'left to you.*sill' "$tmp/out.log" || fail "the summary does not name what is left"

# 4. a failing component stops the run and is named.
: >"$log"
if STUB_FAIL=detent inst --destdir "$dest" >"$tmp/out.log" 2>&1; then fail "a failing component did not fail the run"; fi
grep -q 'detent failed (exit 7)' "$tmp/out.log" || fail "the failure does not name the component: $(cat "$tmp/out.log")"
! grep -q anyview "$log" || fail "a component after the failure ran"

# 5. a missing component repo is exit 2 with its path.
rm -rf -- "${sib:?}/mailo"
inst --dry-run >"$tmp/out.log" 2>&1 && fail "a missing component did not fail"
grep -q 'mailo: no installer' "$tmp/out.log" || fail "the missing component is not named"
echo "installer-check: ok"
