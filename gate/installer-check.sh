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
echo "$1 \$* PREFIX=\${PREFIX:-} DESTDIR=\${DESTDIR:-} MAILO_PREFIX=\${MAILO_PREFIX:-} LINKER=\${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER:-} FLAGS=\${RUSTFLAGS-unset}" >>"$log"
[ "\${STUB_FAIL:-}" != "$2" ] || exit 7
STUB
  chmod +x "$f"
}
stub porter/scripts/install.sh porter
stub detent/scripts/install.sh detent
stub casement/scripts/install.sh casement
stub sill/dist/install.sh sill
stub keycap/install.sh keycap
stub anyview/dist/install.sh anyview
stub mailo/dist/install.sh mailo
stub palmrest/install.sh palmrest
mkdir -p "$sib/detent/target/release"; : >"$sib/detent/target/release/detent"; chmod +x "$sib/detent/target/release/detent"
# A sudo that fails the check when called.
printf '#!/bin/sh\necho sudo >>"%s"\nexit 1\n' "$log" >"$tmp/bin/sudo"; chmod +x "$tmp/bin/sudo"
export PATH="$tmp/bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config"

fail() { echo "installer-check: $*" >&2; exit 1; }
inst() { env -u PREFIX -u DESTDIR -u SYSCONFDIR -u RUSTFLAGS SUDO=asroot DESKTOP_FASTER_LINKER="${STUB_LINKER:-yes}" DESKTOP_HOST_ARCH=x86_64 "$INSTALL" --siblings "$sib" "$@"; }

# 1. dry run: the plan, in order, nothing run.
plan=$(inst --dry-run --destdir "$dest") || fail "dry run failed"
[ ! -s "$log" ] || fail "the dry run ran an installer: $(cat "$log")"
order=$(printf '%s\n' "$plan" | grep -E '^[0-9]+\.' | awk '{print $2}' | tr '\n' ' ')
[ "$order" = "porter detent casement sill keycap anyview mailo palmrest session " ] || fail "plan order is: $order"
printf '%s\n' "$plan" | grep -q 'sill .*yourself' || fail "sill is not left to the person"
printf '%s\n' "$plan" | grep -q 'palmrest .*yourself' || fail "palmrest is not left to the person"
printf '%s\n' "$plan" | grep -q 'session .*runs' || fail "the session step does not run into a staging root"

# 2. a system prefix without root is left to the person, not attempted.
plan=$(inst --dry-run --prefix /usr) || fail "system prefix dry run failed"
printf '%s\n' "$plan" | grep -q 'porter .*yourself (needs root' || fail "a system prefix was not reported as needing root"
printf '%s\n' "$plan" | grep -q 'session .*yourself (needs root' || fail "the session step was not left to the person without root: $plan"
printf '%s\n' "$plan" | grep -q '&& asroot .*install/install.sh --prefix /usr --sysconfdir /etc' || fail "the session root command does not go through the escalation program: $plan"
printf '%s\n' "$plan" | grep -q 'cd .*porter && asroot .*scripts/install.sh --prefix /usr' || fail "the root command does not go through the escalation program: $plan"

# 3. a real run into a staging root passes PREFIX and DESTDIR through, runs the stageable ones, never sudo.
inst --destdir "$dest" --prefix /opt/d >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; fail "staged run failed"; }
# porter always goes to /usr (its data is read from /usr/share only), whatever the desktop prefix.
grep -q "^porter/scripts/install.sh --prefix /usr --sysconfdir /etc --destdir $dest" "$log" || fail "porter did not get /usr and the destdir: $(cat "$log")"
grep -q "^casement/scripts/install.sh --prefix /opt/d --locked --destdir $dest" "$log" || fail "casement did not get the prefix and destdir: $(cat "$log")"
grep -q 'note: porter goes to /usr, not /opt/d' "$tmp/out.log" || fail "the porter prefix note is missing"
# the session step is this repo's own installer: really run, into the staging root
[ -x "$dest/opt/d/bin/desktop-session" ] || fail "desktop-session was not staged under the prefix"
[ -f "$dest/etc/systemd/user/desktop-session.target" ] || fail "the user target was not staged"
[ -f "$dest/usr/share/wayland-sessions/sill-casement.desktop" ] || fail "the login entry was not staged"
[ ! -e "$dest/etc/systemd/user/casement.service" ] || fail "the session installer copied casement.service"
grep -q "^detent/scripts/install.sh  PREFIX=/opt/d DESTDIR=$dest" "$log" || fail "detent did not get PREFIX and DESTDIR"
grep -q "MAILO_PREFIX=$dest/opt/d" "$log" || fail "mailo did not get its prefix"
grep -q "^keycap/install.sh" "$log" || fail "no component ran"
! grep -q sudo "$log" || fail "sudo was called"
[ ! -e "$home/.config" ] || fail "something wrote the scratch ~/.config"
grep -q 'left to you.*sill' "$tmp/out.log" || fail "the summary does not name what is left"

# 3b. the linker: with clang and mold present nothing is overridden; without them the system linker is.
grep -q 'LINKER= FLAGS=unset' "$log" || fail "the linker was overridden although clang and mold are present: $(cat "$log")"
: >"$log"
STUB_LINKER=no inst --destdir "$dest" >"$tmp/out.log" 2>&1 || fail "the run without mold failed"
grep -q 'LINKER=cc FLAGS= ' "$log" || grep -q 'LINKER=cc FLAGS=$' "$log" || fail "no system linker without mold: $(cat "$log")"
grep -q 'faster linker (clang and mold) was not found' "$tmp/out.log" || fail "the missing faster linker was not said"

# 3c. the emoji font: staged under the prefix with its licence; not when --only leaves it out; not when fontconfig
# already has a COLRv1 Noto Color Emoji; fc-cache runs on a real (unstaged) install.
[ -f "$dest/opt/d/share/fonts/quire/Noto-COLRv1.ttf" ] || fail "the emoji font was not staged"
[ -f "$dest/opt/d/share/fonts/quire/OFL-Noto-COLRv1.txt" ] || fail "the font licence was not staged"
rm -rf -- "$tmp/dest2"
inst --destdir "$tmp/dest2" --prefix /opt/d --only porter >/dev/null 2>&1 || fail "--only porter failed"
[ ! -e "$tmp/dest2/opt/d/share/fonts" ] || fail "--only porter installed the font"
mkdir -p "$tmp/fcbin" "$tmp/user"
printf '#!/bin/sh\necho "fc-cache $*" >>"%s"\n' "$log" >"$tmp/fcbin/fc-cache"
printf '#!/bin/sh\necho "/usr/share/fonts/Noto-COLRv1.ttf: Noto Color Emoji:style=Regular"\n' >"$tmp/fcbin/fc-list-present"
printf '#!/bin/sh\necho "/usr/share/fonts/NotoColorEmoji.ttf: Noto Color Emoji:style=Regular"\n' >"$tmp/fcbin/fc-list"
chmod +x "$tmp/fcbin"/*
: >"$log"
PATH="$tmp/fcbin:$PATH" inst --prefix "$tmp/user" --only fonts >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; fail "the font step failed"; }
[ -f "$tmp/user/share/fonts/quire/Noto-COLRv1.ttf" ] || fail "the font was not installed under the prefix"
grep -q "fc-cache -f $tmp/user/share/fonts/quire" "$log" || fail "fc-cache was not run: $(cat "$log")"
rm -rf -- "$tmp/user"; : >"$log"
mv "$tmp/fcbin/fc-list-present" "$tmp/fcbin/fc-list"
PATH="$tmp/fcbin:$PATH" inst --prefix "$tmp/user" --only fonts >"$tmp/out.log" 2>&1 || fail "the font step failed with a system font"
[ ! -e "$tmp/user/share/fonts" ] || fail "the font was installed although fontconfig has a COLRv1 one"
grep -q 'fontconfig already has' "$tmp/out.log" || fail "the skip was not said"
: >"$log"

# 4. a failing component stops the run and is named.
: >"$log"
if STUB_FAIL=detent inst --destdir "$dest" >"$tmp/out.log" 2>&1; then fail "a failing component did not fail the run"; fi
grep -q 'detent failed (exit 7)' "$tmp/out.log" || fail "the failure does not name the component: $(cat "$tmp/out.log")"
! grep -q anyview "$log" || fail "a component after the failure ran"

# 4b. a component whose installer has not landed (casement) is skipped and said, not an error.
rm -f -- "$sib/casement/scripts/install.sh"
plan=$(inst --dry-run --destdir "$dest") || fail "a missing optional installer failed the dry run"
printf '%s\n' "$plan" | grep -q 'casement .*skipped' || fail "the missing casement installer was not reported: $plan"

# 4c. the session uninstall removes the old casement.service only when it is what the old installer shipped.
old="$dest/etc/systemd/user/casement.service"
mkdir -p "$(dirname "$old")"
printf '[Service]\nExecStart=/usr/bin/casement\n' >"$old"
sum=$(sha256sum "$old" | cut -d' ' -f1)
OLD_CASEMENT_UNIT_SHA256=$sum "$HERE/../install/uninstall.sh" --destdir "$dest" --prefix /opt/d >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; fail "uninstall failed"; }
[ ! -e "$old" ] || fail "an unchanged old casement.service was kept"
[ ! -e "$dest/opt/d/bin/desktop-session" ] || fail "the uninstall left desktop-session"
printf '[Service]\nExecStart=/opt/mine/casement\n' >"$old"
OLD_CASEMENT_UNIT_SHA256=$sum "$HERE/../install/uninstall.sh" --destdir "$dest" --prefix /opt/d >"$tmp/out.log" 2>&1 || fail "uninstall failed (changed unit)"
[ -f "$old" ] || fail "a changed casement.service was removed"
grep -q 'kept (not what the earlier installer copied)' "$tmp/out.log" || fail "the kept unit was not reported"

# 5. a missing component repo is exit 2 with its path.
rm -rf -- "${sib:?}/mailo"
inst --dry-run >"$tmp/out.log" 2>&1 && fail "a missing component did not fail"
grep -q 'mailo: no installer' "$tmp/out.log" || fail "the missing component is not named"
echo "installer-check: ok"
