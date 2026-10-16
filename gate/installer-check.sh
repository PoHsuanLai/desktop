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
echo "$1 \$* PREFIX=\${PREFIX:-} DESTDIR=\${DESTDIR:-} MAILO_PREFIX=\${MAILO_PREFIX:-} FLAGS=\${RUSTFLAGS-unset}" >>"$log"
[ "\${STUB_FAIL:-}" != "$2" ] || exit 7
STUB
  chmod +x "$f"
}
stub porter/scripts/install.sh porter
stub stoker/scripts/install.sh stoker
stub almanac/scripts/install.sh almanac
stub docket/scripts/install.sh docket
stub cua/scripts/install.sh cua
stub detent/scripts/install.sh detent
stub casement/scripts/install.sh casement
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
inst() { env -u PREFIX -u DESTDIR -u SYSCONFDIR -u RUSTFLAGS SUDO=asroot "$INSTALL" --siblings "$sib" "$@"; }

# 1. dry run: the plan, in order, nothing run.
plan=$(inst --dry-run --destdir "$dest") || fail "dry run failed"
[ ! -s "$log" ] || fail "the dry run ran an installer: $(cat "$log")"
order=$(printf '%s\n' "$plan" | grep -E '^[0-9]+\.' | awk '{print $2}' | tr '\n' ' ')
[ "$order" = "porter stoker almanac docket cua detent casement sill transom keycap anyview mailo palmrest session " ] || fail "plan order is: $order"
printf '%s\n' "$plan" | grep -q 'sill .*yourself' || fail "sill is not left to the person"
printf '%s\n' "$plan" | grep -q 'palmrest .*yourself' || fail "palmrest is not left to the person"
printf '%s\n' "$plan" | grep -q 'porter .*runs .*scripts/install.sh --prefix /usr/local --sysconfdir /etc --destdir' || fail "porter does not get the desktop prefix and /etc: $plan"
printf '%s\n' "$plan" | grep -q 'stoker .*runs .*scripts/install.sh --prefix /usr/local --sysconfdir /etc --destdir' || fail "stoker does not get the desktop prefix, /etc and the destdir: $plan"
! printf '%s\n' "$plan" | grep -q 'note: .* is not on the session' || fail "the default prefix got the search-path note: $plan"
printf '%s\n' "$plan" | grep -q 'almanac .*runs .*scripts/install.sh --prefix /usr/local --destdir' || fail "almanac does not run into a staging root: $plan"
printf '%s\n' "$plan" | grep -q 'docket .*runs .*scripts/install.sh --prefix /usr/local --destdir' || fail "docket does not run into a staging root: $plan"
printf '%s\n' "$plan" | grep -q 'cua .*runs .*scripts/install.sh --prefix /usr/local --destdir' || fail "cua does not run into a staging root: $plan"
! printf '%s\n' "$plan" | grep -E 'almanac|docket|cua ' | grep -q -- '--sysconfdir' || fail "almanac, docket or cua was given --sysconfdir (their tables are read from /etc/quire only)"
printf '%s\n' "$plan" | grep -q 'session .*runs' || fail "the session step does not run into a staging root"

# 2. a system prefix without root is left to the person, not attempted.
plan=$(inst --dry-run --prefix /usr) || fail "system prefix dry run failed"
printf '%s\n' "$plan" | grep -q 'porter .*yourself (needs root' || fail "a system prefix was not reported as needing root"
printf '%s\n' "$plan" | grep -q 'session .*yourself (needs root' || fail "the session step was not left to the person without root: $plan"
printf '%s\n' "$plan" | grep -q '&& asroot .*install/install.sh --prefix /usr --sysconfdir /etc' || fail "the session root command does not go through the escalation program: $plan"
printf '%s\n' "$plan" | grep -q 'cd .*porter && asroot .*scripts/install.sh --prefix /usr' || fail "the root command does not go through the escalation program: $plan"

# 2b. without a staging root almanac, docket and cua are left to the person, as themselves: their installers refuse to
# run as root and ask for sudo for /etc/quire themselves, so no root command is printed for them.
plan=$(inst --dry-run --prefix "$tmp/user-prefix") || fail "user prefix dry run failed"
for c in almanac docket cua; do
  printf '%s\n' "$plan" | grep -q "$c .*yourself (its caller table" || fail "$c was not left to the person: $plan"
  printf '%s\n' "$plan" | grep -q "cd .*$c && .*scripts/install.sh --prefix $tmp/user-prefix *\$" || fail "$c command is missing: $plan"
  ! printf '%s\n' "$plan" | grep -q "asroot .*$c/scripts/install.sh" || fail "$c was offered as a root command: $plan"
done

# 2c. without a staging root stoker is left to the person, as themselves (its installer asks for sudo itself).
plan=$(inst --dry-run --prefix "$tmp/user-prefix") || fail "user prefix dry run failed"
printf '%s\n' "$plan" | grep -q 'stoker .*yourself (its installer asks for sudo' || fail "stoker was not left to the person: $plan"
! printf '%s\n' "$plan" | grep -q "asroot .*stoker/scripts/install.sh" || fail "stoker was offered as a root command: $plan"

# 2d. a prefix off the session's search paths prints, never writes, how to tell the session: the data dirs line and the unit links.
for p in /opt/d "$tmp/user-prefix"; do
  plan=$(inst --dry-run --prefix "$p") || fail "dry run with prefix $p failed"
  printf '%s\n' "$plan" | grep -q "XDG_DATA_DIRS=$p/share:/usr/local/share:/usr/share\$" || fail "no XDG_DATA_DIRS line for $p: $plan"
  printf '%s\n' "$plan" | grep -q "environment.d" || fail "the note does not name environment.d for $p: $plan"
  printf '%s\n' "$plan" | grep -q "ln -sf $p/lib/systemd/user/\* /usr/local/lib/systemd/user/" || fail "no unit link line for $p: $plan"
done
for p in /usr /usr/local; do
  ! inst --dry-run --prefix "$p" | grep -q 'XDG_DATA_DIRS=' || fail "prefix $p got the search-path note"
done
[ ! -e "$home/.config/environment.d" ] || fail "the note was written, not printed"

# 3. a real run into a staging root passes PREFIX and DESTDIR through, runs the stageable ones, never sudo.
inst --destdir "$dest" --prefix /opt/d >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; fail "staged run failed"; }
# porter goes under the same prefix as everything else (its daemons find what they ship under XDG_DATA_DIRS),
# with the caller tables in --sysconfdir.
grep -q "^porter/scripts/install.sh --prefix /opt/d --sysconfdir /etc --destdir $dest" "$log" || fail "porter did not get the prefix, /etc and the destdir: $(cat "$log")"
grep -q "^stoker/scripts/install.sh --prefix /opt/d --sysconfdir /etc --destdir $dest" "$log" || fail "stoker did not get the prefix, /etc and the destdir: $(cat "$log")"
grep -q "^casement/scripts/install.sh --prefix /opt/d --locked --destdir $dest" "$log" || fail "casement did not get the prefix and destdir: $(cat "$log")"
! grep -q 'note: porter goes to' "$tmp/out.log" || fail "a porter prefix note is still printed: $(cat "$tmp/out.log")"
# the session step is this repo's own installer: really run, into the staging root
[ -x "$dest/opt/d/bin/desktop-session" ] || fail "desktop-session was not staged under the prefix"
[ -f "$dest/etc/systemd/user/desktop-session.target" ] || fail "the user target was not staged"
[ -f "$dest/usr/share/wayland-sessions/sill-casement.desktop" ] || fail "the login entry was not staged"
[ ! -e "$dest/etc/systemd/user/casement.service" ] || fail "the session installer copied casement.service"
grep -q "^almanac/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "almanac did not get the prefix and destdir: $(cat "$log")"
grep -q "^docket/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "docket did not get the prefix and destdir: $(cat "$log")"
grep -q "^cua/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "cua did not get the prefix and destdir: $(cat "$log")"
grep -q "^detent/scripts/install.sh  PREFIX=/opt/d DESTDIR=$dest" "$log" || fail "detent did not get PREFIX and DESTDIR"
grep -q "^transom/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "transom did not get the prefix and destdir"
grep -q "MAILO_PREFIX=$dest/opt/d" "$log" || fail "mailo did not get its prefix"
grep -q "^keycap/install.sh" "$log" || fail "no component ran"
! grep -q sudo "$log" || fail "sudo was called"
[ ! -e "$home/.config" ] || fail "something wrote the scratch ~/.config"
grep -q 'left to you.*sill' "$tmp/out.log" || fail "the summary does not name what is left"

# 3b. the build: detent, the one tree this installer builds itself, is built with the system's linker. cargo runs
# from / with --manifest-path (so the tree's .cargo/config.toml, clang and mold, is not read), the tree's pinned
# toolchain goes in RUSTUP_TOOLCHAIN, and neither RUSTFLAGS nor a linker variable is set. cargo here is a stub.
grep -q 'FLAGS=unset' "$log" || fail "an installer was given RUSTFLAGS: $(cat "$log")"
! grep -q 'LINKER' "$log" || fail "an installer was given a linker: $(cat "$log")"
rm -f -- "$sib/detent/target/release/detent"
printf '[toolchain]\nchannel = "9.9.9"\n' >"$sib/detent/rust-toolchain.toml"
printf '#!/bin/sh\necho "cargo cwd=$PWD TC=${RUSTUP_TOOLCHAIN:-} FLAGS=${RUSTFLAGS-unset} LINKER=${CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER:-} $*" >>"%s"\nmkdir -p "$CARGO_TARGET_DIR/release" && : >"$CARGO_TARGET_DIR/release/detent" && chmod +x "$CARGO_TARGET_DIR/release/detent"\n' "$log" >"$tmp/bin/cargo"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/rustup"
chmod +x "$tmp/bin/cargo" "$tmp/bin/rustup"
: >"$log"
inst --destdir "$dest" --only detent >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; fail "the detent build run failed"; }
grep -q "^cargo cwd=/ TC=9.9.9 FLAGS=unset LINKER= build --release --locked --manifest-path $sib/detent/Cargo.toml --config net.git-fetch-with-cli=true\$" "$log" || fail "detent was not built from / with --manifest-path: $(cat "$log")"
rm -f -- "$tmp/bin/cargo" "$tmp/bin/rustup"
: >"$log"

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
