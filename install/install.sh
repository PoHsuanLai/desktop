#!/usr/bin/env bash
# Install the "sill (casement)" session: the session script, the portal choice for the quire
# desktop, the user target and the login-screen entry. Run as yourself; it never runs sudo (a
# destination you cannot write stops it with the command to run as root). Safe to run again.
#
#   install/install.sh --dry-run    print every step, change nothing
#   install/install.sh              do it
#   (flags: see install/lib.sh)
#
# Not installed here: casement (and its casement.service, which casement's own installer puts under its prefix),
# sill and xdg-desktop-portal-wlr themselves (their own installers and packages), other sessions (left untouched), and
# anything under $HOME. install/uninstall.sh removes exactly the files listed below.
set -euo pipefail
ORIG_ARGS=("$@")
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
parse_flags "$@"
[ "$dry" = 0 ] || echo "dry run: nothing below is executed"

step "1/3 checks"
for tool in casement sill; do
  command -v "$tool" >/dev/null || note "WARNING: $tool is not on PATH; the session cannot start without it"
done
unit_found=0
for unit_dir in "$prefix/lib/systemd/user" /usr/local/lib/systemd/user /usr/lib/systemd/user; do
  [ ! -f "$destdir$unit_dir/casement.service" ] || unit_found=1
done
[ "$unit_found" = 1 ] || note "WARNING: no casement.service in $prefix/lib/systemd/user; the session needs it and cannot start casement without it (../install.sh installs casement with its unit)"
if [ -f "$destdir$sysconfdir/systemd/user/casement.service" ]; then
  note "WARNING: $sysconfdir/systemd/user/casement.service is an older copy and hides the one casement's installer puts under $prefix/lib/systemd/user; remove it: $(as_root_hint rm -f "$sysconfdir/systemd/user/casement.service")"
fi
portal_found=0
for portal in /usr/libexec/xdg-desktop-portal-wlr /usr/lib/xdg-desktop-portal-wlr /usr/lib/*/xdg-desktop-portal-wlr; do
  [ ! -x "$portal" ] || portal_found=1
done
[ "$portal_found" = 1 ] || note "WARNING: xdg-desktop-portal-wlr is missing (screenshots and screen sharing need it): $(install_hint portal-wlr | tr '\n' ' ')"

step "2/3 the files"
dests=()
while read -r _ _ dest; do dests+=("$dest"); done < <(files)
need_write "${dests[@]}"
while read -r mode source dest; do
  note "$destdir$dest ($mode)"
  [ "$dry" = 1 ] || {
    install -d "$(dirname "$destdir$dest")"
    content "$source" | install -m "$mode" /dev/stdin "$destdir$dest"
  }
done < <(files)

step "3/3 the user manager"
if [ -n "$destdir" ]; then
  note "staged under $destdir: nothing to reload"
elif [ "$dry" = 1 ]; then
  note "\$ systemctl --user daemon-reload"
else
  systemctl --user daemon-reload || note "could not reload the user manager; log out and in"
fi

step "done"
note "Pick \"sill (casement)\" at the login screen. First-login checks (not testable without a login):"
note "  the guard's real tty path, sill and the wlr portal against the real casement, the target, casement.service"
note "  the activation environment, a screen share through the wlr portal, logout through sill's power menu."
