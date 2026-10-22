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
echo "$1 \$* PREFIX=\${PREFIX:-} DESTDIR=\${DESTDIR:-} MAILO_PREFIX=\${MAILO_PREFIX:-} FILES_PREFIX=\${FILES_PREFIX:-} FILES_DESTDIR=\${FILES_DESTDIR:-} FLAGS=\${RUSTFLAGS-unset}" >>"$log"
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
stub files/dist/install.sh files
stub palmrest/install.sh palmrest
# The two units the session installer puts in /etc/systemd/user, as the casement and sill checkouts ship them.
mkdir -p "$sib/casement/dist" "$sib/sill/dist"
# the stub units carry the loader line the real ones do (peephole's list), so the loader step below checks them as it would a release
unset_line='UnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT GCONV_PATH GIO_EXTRA_MODULES GTK_MODULES GTK_PATH GST_PLUGIN_PATH GST_PLUGIN_SYSTEM_PATH LIBGL_DRIVERS_PATH MESA_LOADER_DRIVER_OVERRIDE __EGL_VENDOR_LIBRARY_DIRS __EGL_VENDOR_LIBRARY_FILENAMES GBM_BACKENDS_PATH LIBVA_DRIVERS_PATH VK_ICD_FILENAMES VK_DRIVER_FILES VK_ADD_DRIVER_FILES VK_LAYER_PATH VK_ADD_LAYER_PATH VK_INSTANCE_LAYERS VK_LOADER_LAYERS_ENABLE'
printf '[Service]\nExecStart=/usr/bin/casement $CASEMENT_SESSION_ARGS\n%s\n' "$unset_line" >"$sib/casement/dist/casement.service"
printf '[Service]\nExecStart=/usr/bin/sill run\n%s\n' "$unset_line" >"$sib/sill/dist/sill.service"
mkdir -p "$sib/detent/target/release"; : >"$sib/detent/target/release/detent"; chmod +x "$sib/detent/target/release/detent"
# The input service, the keyboard map and the touchpad service: the files install/system.sh takes from their checkouts (the unit as
# each repo ships it), and their programs, already built (so no compiler runs here). keycap's and palmrest's own installers,
# stubbed above, must never run.
mkdir -p "$sib/turnstile/dist" "$sib/turnstile/target/release" "$sib/keycap/dist" "$sib/keycap/target/release" "$sib/palmrest/dist" "$sib/palmrest/target/release"
printf '[Socket]\nListenSequentialPacket=/run/turnstile/input.sock\nSocketMode=0666\n' >"$sib/turnstile/dist/turnstile.socket"
printf '[Service]\nExecStart=/usr/local/bin/turnstile\nUser=root\n%s\n' "$unset_line" >"$sib/turnstile/dist/turnstile.service"
printf 'KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0600", GROUP="root", TAG-="uaccess", OPTIONS+="static_node=uinput"\n' >"$sib/turnstile/dist/72-turnstile.rules"
printf 'uinput\n' >"$sib/turnstile/dist/turnstile-modules.conf"
printf '[Service]\nExecStart=/usr/local/bin/keycap\nDynamicUser=yes\n%s\n' "$unset_line" >"$sib/keycap/dist/keycap.service"
printf '// polkit\n' >"$sib/keycap/dist/keycap.polkit.rules"
printf 'KERNEL=="uinput", GROUP="input", MODE="0660"\n' >"$sib/keycap/dist/70-keycap.rules"
printf '[Service]\nDeviceAllow=/dev/uinput rw\n' >"$sib/keycap/dist/keycap.uinput.conf"
printf '[Service]\nExecStart=/usr/local/bin/palmrest\nDynamicUser=yes\n%s\n' "$unset_line" >"$sib/palmrest/dist/palmrest.service"
printf 'SUBSYSTEM=="hidraw", KERNELS=="0005:004C:0269.*", GROUP="input", MODE="0660"\n' >"$sib/palmrest/dist/70-palmrest.rules"
printf 'options hid_magicmouse emulate_scroll_wheel=0 emulate_3button=1\n' >"$sib/palmrest/dist/99-palmrest.conf"
for b in turnstile keycap palmrest; do printf '#!/bin/sh\n' >"$sib/$b/target/release/$b"; chmod +x "$sib/$b/target/release/$b"; done
# A sudo that fails the check when called.
printf '#!/bin/sh\necho sudo >>"%s"\nexit 1\n' "$log" >"$tmp/bin/sudo"; chmod +x "$tmp/bin/sudo"
export PATH="$tmp/bin:$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config"

fail() { echo "installer-check: $*" >&2; exit 1; }
inst() { env -u PREFIX -u DESTDIR -u SYSCONFDIR -u RUSTFLAGS SUDO=asroot "$INSTALL" --siblings "$sib" "$@"; }

# 1. dry run: the plan, in order, nothing run.
plan=$(inst --dry-run --destdir "$dest") || fail "dry run failed"
[ ! -s "$log" ] || fail "the dry run ran an installer: $(cat "$log")"
order=$(printf '%s\n' "$plan" | grep -E '^[0-9]+\.' | awk '{print $2}' | tr '\n' ' ')
[ "$order" = "callers porter stoker almanac docket cua detent casement sill transom turnstile keycap anyview mailo files palmrest session " ] || fail "plan order is: $order"
printf '%s\n' "$plan" | grep -q 'callers .*runs .*install/system.sh callers --destdir' || fail "the callers table is not placed first, into the staging root: $plan"
printf '%s\n' "$plan" | grep -q 'turnstile .*runs .*install/system.sh turnstile --prefix /usr/local --destdir' || fail "the input service does not run into a staging root: $plan"
printf '%s\n' "$plan" | grep -q 'keycap .*runs .*install/system.sh keycap --prefix /usr/local --destdir' || fail "the keyboard map is not placed by the desktop's own script: $plan"
printf '%s\n' "$plan" | grep -q 'palmrest .*runs .*install/system.sh palmrest --prefix /usr/local --destdir' || fail "the touchpad service is not placed by the desktop's own script, into the staging root: $plan"
! printf '%s\n' "$plan" | grep -i 'palmrest' | grep -q 'your home' || fail "palmrest is still said to be installed under the home: $plan"
printf '%s\n' "$plan" | grep -q 'sill .*yourself' || fail "sill is not left to the person"
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
printf '%s\n' "$plan" | grep -q 'callers .*yourself (needs root: /etc/quire' || fail "the callers table was not left to the person without root: $plan"
printf '%s\n' "$plan" | grep -q '&& asroot .*install/system.sh callers *$' || fail "the callers root command does not go through the escalation program: $plan"
printf '%s\n' "$plan" | grep -q '&& asroot .*install/system.sh turnstile --prefix /usr --siblings' || fail "the input service root command is missing: $plan"
printf '%s\n' "$plan" | grep -q '&& asroot .*install/system.sh palmrest --prefix /usr --siblings' || fail "the touchpad service root command is missing: $plan"

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

# 2e. a program root runs never lives where the person can replace it. A user-owned prefix (--prefix ~/.local) is refused by
# install/system.sh for the input service, the keyboard map and the touchpad service, and install.sh puts those three under /usr/local instead and says so;
# a prefix root holds is kept. (Without a staging root: the check judges the real folders.)
mkdir -p "$tmp/user-prefix/bin"
for part in turnstile keycap palmrest; do
  if "$HERE/../install/system.sh" "$part" --dry-run --prefix "$tmp/user-prefix" --siblings "$sib" >"$tmp/out-unheld.log" 2>&1; then
    fail "install/system.sh $part accepted a prefix the person owns: $(cat "$tmp/out-unheld.log")"
  fi
  grep -q "is not a safe place for a program that root runs" "$tmp/out-unheld.log" || fail "the refusal for $part does not say why: $(cat "$tmp/out-unheld.log")"
  "$HERE/../install/system.sh" "$part" --dry-run --prefix /usr --siblings "$sib" >"$tmp/out-held.log" 2>&1 || { cat "$tmp/out-held.log" >&2; fail "install/system.sh $part refused /usr, which root holds"; }
  plan=$(inst --dry-run --prefix "$tmp/user-prefix" --only "$part") || fail "dry run with a user prefix failed for $part"
  printf '%s\n' "$plan" | grep -q "install/system.sh $part --prefix /usr/local" || fail "$part was not moved to /usr/local for a user prefix: $plan"
  ! printf '%s\n' "$plan" | grep -q "install/system.sh $part --prefix $tmp/user-prefix" || fail "$part was planned under the user's prefix: $plan"
  printf '%s\n' "$plan" | grep -q "note: $part runs as root, so its program goes under /usr/local" || fail "the move of $part was not said: $plan"
  plan=$(inst --dry-run --prefix /usr --only "$part") || fail "dry run with /usr failed for $part"
  printf '%s\n' "$plan" | grep -q "install/system.sh $part --prefix /usr " || fail "$part left /usr, which root holds: $plan"
done
[ -z "$(find "$tmp/user-prefix" -type f)" ] || fail "a refused install left files under the person's prefix"
# a staging root is not judged: the folder it becomes is the packager's
plan=$(inst --dry-run --destdir "$dest" --prefix "$tmp/user-prefix" --only turnstile) || fail "staged dry run with a user prefix failed"
printf '%s\n' "$plan" | grep -q "install/system.sh turnstile --prefix $tmp/user-prefix --destdir" || fail "a staged prefix was moved: $plan"

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
# the portal frontend's own unit gets a root-held drop-in that unsets the loader variables (NEW-PI-1): staged next to the units, the
# same bytes as the repo's, and complete against peephole's list (the check skips, exit 2, when no peephole checkout is beside this one)
dropin="$dest/etc/systemd/user/xdg-desktop-portal.service.d/10-quire.conf"
[ -f "$dropin" ] || fail "the portal frontend's drop-in was not staged"
cmp -s "$HERE/../session/xdg-desktop-portal.service.d/10-quire.conf" "$dropin" || fail "the staged portal drop-in is not the repo's"
[ "$(stat -c %a "$dropin")" = 644 ] || fail "the portal drop-in is not mode 644"
rc=0; "$HERE/check-loader-unset.sh" --siblings "$sib" --dropin "$dropin" >"$tmp/loader.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 2 ] || fail "the staged portal drop-in does not unset every loader variable: $(cat "$tmp/loader.log")"
grep -q '^Wants=slipway.service$' "$dest/etc/systemd/user/desktop-session.target" || fail "the user target does not want the update service"
[ -f "$dest/usr/share/wayland-sessions/sill-casement.desktop" ] || fail "the login entry was not staged"
grep -q '^ExecStart=/opt/d/bin/casement \$CASEMENT_SESSION_ARGS$' "$dest/etc/systemd/user/casement.service" || fail "casement.service was not staged with the prefix and the session arguments: $(cat "$dest/etc/systemd/user/casement.service" 2>&1)"
grep -q '^ExecStart=/opt/d/bin/sill run$' "$dest/etc/systemd/user/sill.service" || fail "sill.service was not staged with the prefix: $(cat "$dest/etc/systemd/user/sill.service" 2>&1)"
[ "$(stat -c %a "$dest/etc/systemd/user/casement.service")" = 644 ] || fail "casement.service is not mode 644"
grep -q "^almanac/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "almanac did not get the prefix and destdir: $(cat "$log")"
grep -q "^docket/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "docket did not get the prefix and destdir: $(cat "$log")"
grep -q "^cua/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "cua did not get the prefix and destdir: $(cat "$log")"
grep -q "^detent/scripts/install.sh  PREFIX=/opt/d DESTDIR=$dest" "$log" || fail "detent did not get PREFIX and DESTDIR"
grep -q "^transom/scripts/install.sh --prefix /opt/d --destdir $dest" "$log" || fail "transom did not get the prefix and destdir"
grep -q "MAILO_PREFIX=$dest/opt/d" "$log" || fail "mailo did not get its prefix"
grep -q "FILES_PREFIX=/opt/d FILES_DESTDIR=$dest" "$log" || fail "files did not get its prefix and destdir"
! grep -q "^keycap/install.sh" "$log" || fail "keycap's own installer ran: it gives the input group /dev/uinput and the service a drop-in to open it"
! grep -q "^palmrest/install.sh" "$log" || fail "palmrest's own installer ran: the desktop places the touchpad service with install/system.sh"
grep -q "^transom/scripts/install.sh" "$log" || fail "no component ran"
# the desktop's own system files: the callers table (an exact copy, 644), the input service and the keyboard map
cmp -s "$HERE/../dist/desktop-callers.toml" "$dest/etc/quire/desktop-callers.toml" || fail "the callers table was not staged as it is in dist/"
[ "$(stat -c %a "$dest/etc/quire/desktop-callers.toml")" = 644 ] || fail "the callers table is not mode 644"
for f in usr/lib/systemd/system/turnstile.socket usr/lib/systemd/system/turnstile.service etc/udev/rules.d/72-turnstile.rules etc/modules-load.d/turnstile.conf \
  opt/d/bin/turnstile usr/lib/systemd/system/keycap.service etc/polkit-1/rules.d/keycap.polkit.rules opt/d/bin/keycap usr/lib/keycap/keycap.toml; do
  [ -f "$dest/$f" ] || fail "$f was not staged"
done
grep -q '^ExecStart=/opt/d/bin/turnstile$' "$dest/usr/lib/systemd/system/turnstile.service" || fail "turnstile.service does not start the installed program: $(cat "$dest/usr/lib/systemd/system/turnstile.service")"
grep -q '^ExecStart=/opt/d/bin/keycap$' "$dest/usr/lib/systemd/system/keycap.service" || fail "keycap.service does not start the installed program"
grep -q 'rules = \[ { when = "capslock", then = "ctrl+space" } \]\|when = "capslock", then = "ctrl+space"' "$dest/usr/lib/keycap/keycap.toml" || fail "the vendor keycap.toml has no Caps Lock rule"
grep -q 'when = "shift+capslock", then = "capslock"' "$dest/usr/lib/keycap/keycap.toml" || fail "the vendor keycap.toml has no Shift+Caps Lock rule (keycap refuses a Shift trigger in a user layer)"
cmp -s "$HERE/../dist/keycap.toml" "$dest/usr/lib/keycap/keycap.toml" || fail "the vendor keycap.toml was not staged as it is in dist/"
[ "$(stat -c %a "$dest/usr/lib/keycap/keycap.toml")" = 644 ] || fail "the vendor keycap.toml is not mode 644"
# the touchpad service is a system service like keycap: the program, the unit (a plain file, started by the installed program), the rule
# that gives the mouse's raw node to the input group and no person, and the module options; nothing for /dev/uinput, and no user unit
for f in opt/d/bin/palmrest usr/lib/systemd/system/palmrest.service etc/udev/rules.d/70-palmrest.rules etc/modprobe.d/99-palmrest.conf; do
  [ -f "$dest/$f" ] || fail "$f was not staged"
done
grep -q '^ExecStart=/opt/d/bin/palmrest$' "$dest/usr/lib/systemd/system/palmrest.service" || fail "palmrest.service does not start the installed program: $(cat "$dest/usr/lib/systemd/system/palmrest.service")"
[ ! -e "$dest/etc/systemd/user/palmrest.service" ] || fail "a user unit for palmrest was staged"
grep -q 'GROUP="input"' "$dest/etc/udev/rules.d/70-palmrest.rules" || fail "the hidraw rule does not give the node to the input group"
! grep -q 'uaccess' "$dest/etc/udev/rules.d/70-palmrest.rules" || fail "the hidraw rule gives the node to the person"
[ -z "$(find "$dest" -name 'palmrest-modules.conf' -o -name 'palmrest.conf')" ] || fail "palmrest's own module list was staged (the input service loads uinput)"
# keycap.service is the same file from install.sh and from a release (slipway replaces a system file only when it is absent, equal or its own
# earlier one): the path is the one slipway's list names, and at the default prefix the installed unit is the checkout's unit byte for byte,
# which is what build.sh stages (no retarget; /usr/local/bin/keycap is the link exports.toml makes to bin/keycap)
grep -qE '^/usr/lib/systemd/system +exact +keycap\.service$' "$HERE/../release/system-files.list" || fail "slipway's list (release/system-files.list) does not name /usr/lib/systemd/system/keycap.service"
inst --destdir "$tmp/dest-default" --prefix /usr/local --only keycap,palmrest >"$tmp/out-default.log" 2>&1 || { cat "$tmp/out-default.log" >&2; fail "the keyboard map or touchpad step failed at the default prefix"; }
cmp -s "$sib/palmrest/dist/palmrest.service" "$tmp/dest-default/usr/lib/systemd/system/palmrest.service" || fail "palmrest.service from install.sh at the default prefix is not the unit a release stages: $(cat "$tmp/dest-default/usr/lib/systemd/system/palmrest.service" 2>&1)"
grep -qE '^/usr/lib/systemd/system +exact +palmrest\.service$' "$HERE/../release/system-files.list" || fail "slipway's list (release/system-files.list) does not name /usr/lib/systemd/system/palmrest.service"
grep -qF 'put_system 644 "$d/dist/palmrest.service" /usr/lib/systemd/system/palmrest.service' "$HERE/../release/build.sh" || fail "release/build.sh does not stage palmrest.service at /usr/lib/systemd/system"
! grep -q 'retarget.*palmrest\.service' "$HERE/../release/build.sh" || fail "release/build.sh rewrites palmrest.service's ExecStart: install.sh's unit and the release's would differ"
cmp -s "$sib/keycap/dist/keycap.service" "$tmp/dest-default/usr/lib/systemd/system/keycap.service" || fail "keycap.service from install.sh at the default prefix is not the unit a release stages: $(cat "$tmp/dest-default/usr/lib/systemd/system/keycap.service" 2>&1)"
grep -qF 'put_system 644 "$d/dist/keycap.service" /usr/lib/systemd/system/keycap.service' "$HERE/../release/build.sh" || fail "release/build.sh does not stage keycap.service at /usr/lib/systemd/system"
! grep -q 'retarget.*keycap\.service' "$HERE/../release/build.sh" || fail "release/build.sh rewrites keycap.service's ExecStart: install.sh's unit and the release's would differ"
grep -A1 -x 'link = "/usr/local/bin/keycap"' "$HERE/../release/exports.toml" | grep -qx 'target = "bin/keycap"' || fail "release/exports.toml has no /usr/local/bin/keycap link to bin/keycap"
# /etc/keycap is the administrator's: the install writes nothing there
[ ! -e "$dest/etc/keycap" ] || fail "the install wrote into /etc/keycap: $(ls -A "$dest/etc/keycap")"
# nothing gives the person, or a group, the device file; the old stand-alone pieces are not staged
[ ! -e "$dest/etc/udev/rules.d/70-keycap.rules" ] || fail "keycap's group rule for /dev/uinput was staged"
[ -z "$(find "$dest" -name '*uinput.conf' -o -name '10-uinput*')" ] || fail "a uinput drop-in was staged: $(find "$dest" -name '*uinput.conf' -o -name '10-uinput*')"
if grep -rh 'uaccess' "$dest/etc/udev/rules.d" 2>/dev/null | grep -v 'TAG-="uaccess"' | grep -q .; then fail "a staged rule gives the person a device file"; fi
# a second run replaces a vendor keycap.toml that was changed, and leaves the administrator's file alone
printf '[profile.default]\nrules = []\n' >"$dest/usr/lib/keycap/keycap.toml"
mkdir -p "$dest/etc/keycap"; printf '[profile.default]\nrules = []\n' >"$dest/etc/keycap/keycap.toml"
inst --destdir "$dest" --prefix /opt/d --only keycap >"$tmp/out2.log" 2>&1 || { cat "$tmp/out2.log" >&2; fail "the keyboard map step failed the second time"; }
cmp -s "$HERE/../dist/keycap.toml" "$dest/usr/lib/keycap/keycap.toml" || fail "a changed vendor keycap.toml was not replaced"
[ "$(cat "$dest/etc/keycap/keycap.toml")" = "$(printf '[profile.default]\nrules = []')" ] || fail "the administrator's keycap.toml was changed"
# the removal takes away what is unchanged (the vendor file) and never looks at /etc/keycap
"$HERE/../install/system.sh" --remove keycap --destdir "$dest" --prefix /opt/d --siblings "$sib" >"$tmp/out3.log" 2>&1 || { cat "$tmp/out3.log" >&2; fail "removing the keyboard map failed"; }
[ ! -e "$dest/opt/d/bin/keycap" ] || fail "the keyboard map program was kept by the removal"
[ ! -e "$dest/usr/lib/keycap/keycap.toml" ] || fail "the vendor keycap.toml was kept by the removal"
[ -f "$dest/etc/keycap/keycap.toml" ] || fail "the administrator's keycap.toml was removed"
"$HERE/../install/system.sh" --remove turnstile --destdir "$dest" --prefix /opt/d --siblings "$sib" >"$tmp/out3.log" 2>&1 || fail "removing the input service failed"
[ ! -e "$dest/etc/udev/rules.d/72-turnstile.rules" ] || fail "the device rule was kept by the removal"
"$HERE/../install/system.sh" --remove palmrest --destdir "$dest" --prefix /opt/d --siblings "$sib" >"$tmp/out3.log" 2>&1 || { cat "$tmp/out3.log" >&2; fail "removing the touchpad service failed"; }
[ ! -e "$dest/opt/d/bin/palmrest" ] || fail "the touchpad program was kept by the removal"
[ ! -e "$dest/usr/lib/systemd/system/palmrest.service" ] || fail "the touchpad unit was kept by the removal"
[ ! -e "$dest/etc/udev/rules.d/70-palmrest.rules" ] || fail "the hidraw rule was kept by the removal"
inst --destdir "$dest" --prefix /opt/d --only keycap,turnstile,palmrest >/dev/null 2>&1 || fail "the input steps did not run again"
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

# 3d. the loader-variable check itself, on generated trees: a unit that lacks one name of the list is a fault, a complete one passes, a
# unit on the debt list that is complete is a fault, and the drop-in is held to the same list.
lt="$tmp/loader"; mkdir -p "$lt/peephole/peephole-core/src" "$lt/sibs/x/dist" "$lt/sibs/y/dist" "$lt/sibs/desktop"
printf 'pub const LOADER_VARIABLES: [&str; 3] = [\n    "LD_PRELOAD",\n    "LD_LIBRARY_PATH",\n    "GTK_PATH",\n];\n' >"$lt/peephole/peephole-core/src/facts.rs"
printf '[[peer]]\napp = "a"\nunit = "a.service"\nexe = ["/usr/bin/a"]\nrole = "r"\n[[peer]]\napp = "b"\nunit = "b.service"\nexe = ["/usr/bin/b"]\nrole = "r"\n' >"$lt/table.toml"
printf '[Service]\nUnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH\nUnsetEnvironment=GTK_PATH\n' >"$lt/sibs/x/dist/a.service"
printf '[Service]\nUnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH\n' >"$lt/sibs/y/dist/b.service"
printf '[Service]\nUnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH GTK_PATH\n' >"$lt/dropin.conf"
: >"$lt/pending.txt"
loader() { "$HERE/check-loader-unset.sh" --peephole "$lt/peephole" --siblings "$lt/sibs" --table "$lt/table.toml" --pending "$lt/pending.txt" "$@" >"$lt/out.log" 2>&1; }
loader && fail "a unit that lacks GTK_PATH passed the loader check: $(cat "$lt/out.log")"
grep -q 'b.service .*does not unset: GTK_PATH' "$lt/out.log" || fail "the loader check does not name the unit and the variable: $(cat "$lt/out.log")"
printf 'b.service y\n' >"$lt/pending.txt"
loader || fail "a pending unit that is still missing a name broke the check: $(cat "$lt/out.log")"
printf 'UnsetEnvironment=GTK_PATH\n' >>"$lt/sibs/y/dist/b.service"
loader && fail "a complete unit still on the debt list was accepted"
: >"$lt/pending.txt"
loader || fail "complete units were refused: $(cat "$lt/out.log")"
printf '[Service]\nUnsetEnvironment=LD_PRELOAD\n' >"$lt/short.conf"
loader --dropin "$lt/short.conf" && fail "an incomplete drop-in was accepted"
loader --dropin "$lt/dropin.conf" || fail "a complete drop-in was refused: $(cat "$lt/out.log")"

# 3e. the session's settings file is read as data (ROOT-14): a line that would run a program is ignored, not run; the three
# settings count, with or without quotes; a number setting needs a number. The function is taken out of the script and run alone.
se="$tmp/session-env"; mkdir -p "$se"
log() { printf '%s\n' "$*" >>"$se/log"; }
eval "$(sed -n '/^read_settings() {$/,/^}$/p' "$HERE/../session/desktop-session")"
printf '# a comment\nDESKTOP_SESSION_QUICK_SECS=7\nDESKTOP_SESSION_BACKEND_ARGS="--backend headless"\nDESKTOP_SESSION_FIRST_RUN_DELAY=soon\nPATH=/evil\ntouch %s/ran\n$(touch %s/ran2)\n' "$se" "$se" >"$se/session.env"
( unset DESKTOP_SESSION_QUICK_SECS DESKTOP_SESSION_BACKEND_ARGS DESKTOP_SESSION_FIRST_RUN_DELAY
  read_settings "$se/session.env"
  [ "$DESKTOP_SESSION_QUICK_SECS" = 7 ] || exit 1
  [ "$DESKTOP_SESSION_BACKEND_ARGS" = "--backend headless" ] || exit 2
  [ -z "${DESKTOP_SESSION_FIRST_RUN_DELAY:-}" ] || exit 3
  [ "$PATH" != /evil ] || exit 4 ) || fail "session.env was not read as the three settings (exit $?)"
[ ! -e "$se/ran" ] && [ ! -e "$se/ran2" ] || fail "session.env ran a command"
grep -q 'ignored PATH' "$se/log" || fail "the ignored name was not logged"
unset -f log read_settings

# 4. a failing component stops the run and is named.
: >"$log"
if STUB_FAIL=detent inst --destdir "$dest" >"$tmp/out.log" 2>&1; then fail "a failing component did not fail the run"; fi
grep -q 'detent failed (exit 7)' "$tmp/out.log" || fail "the failure does not name the component: $(cat "$tmp/out.log")"
! grep -q anyview "$log" || fail "a component after the failure ran"

# 4b. a component whose installer has not landed (casement) is skipped and said, not an error.
rm -f -- "$sib/casement/scripts/install.sh"
plan=$(inst --dry-run --destdir "$dest") || fail "a missing optional installer failed the dry run"
printf '%s\n' "$plan" | grep -q 'casement .*skipped' || fail "the missing casement installer was not reported: $plan"

# 4c. the session uninstall removes the two units only while they are still what the installer wrote.
units="$dest/etc/systemd/user"
"$HERE/../install/uninstall.sh" --destdir "$dest" --prefix /opt/d --siblings "$sib" >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; fail "uninstall failed"; }
[ ! -e "$units/casement.service" ] || fail "an unchanged casement.service was kept"
[ ! -e "$units/sill.service" ] || fail "an unchanged sill.service was kept"
[ ! -e "$dest/opt/d/bin/desktop-session" ] || fail "the uninstall left desktop-session"
inst --destdir "$dest" --prefix /opt/d --only session >/dev/null 2>&1 || fail "the session step did not run again"
printf '[Service]\nExecStart=/opt/mine/casement\n' >"$units/casement.service"
"$HERE/../install/uninstall.sh" --destdir "$dest" --prefix /opt/d --siblings "$sib" >"$tmp/out.log" 2>&1 || fail "uninstall failed (changed unit)"
[ -f "$units/casement.service" ] || fail "a changed casement.service was removed"
grep -q 'kept (not what the installer wrote)' "$tmp/out.log" || fail "the kept unit was not reported"
[ ! -e "$units/sill.service" ] || fail "an unchanged sill.service was kept (second run)"

# 4d. a unit whose checkout is missing is warned about and skipped, not an error.
rm -f -- "$sib/sill/dist/sill.service"
out=$("$HERE/../install/install.sh" --dry-run --destdir "$dest" --prefix /opt/d --siblings "$sib" 2>&1) || fail "a missing unit source failed the session installer"
printf '%s\n' "$out" | grep -q 'WARNING: .*sill.service is missing' || fail "the missing sill.service was not warned about: $out"

# 5. a missing component repo is exit 2 with its path.
rm -rf -- "${sib:?}/mailo"
inst --dry-run >"$tmp/out.log" 2>&1 && fail "a missing component did not fail"
grep -q 'mailo: no installer' "$tmp/out.log" || fail "the missing component is not named"
echo "installer-check: ok"
