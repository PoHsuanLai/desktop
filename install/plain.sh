#!/usr/bin/env bash
# The plain installer behind the justfile: build every part as you, then install it, one line per part.
# Each part's whole output goes to the log; a failure prints the log's last lines and stops.
#
#   install/plain.sh build   [PART...]   build as you (cargo, release, this system's linker)
#   install/plain.sh install [PART...]   build, then install; sudo asks once, at the start
#
# With no PART, every part in install order. PREFIX (default /usr/local) and SIBLINGS (default the
# parent of this repo) come from the environment. Each part's own installer does the work; this file only
# says how to build it as you and how to install what was built, so nothing builds as root.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
desktop=$(dirname "$here")
siblings=${SIBLINGS:-$(dirname "$desktop")}
prefix=${PREFIX:-/usr/local}
log=${XDG_STATE_HOME:-$HOME/.local/state}/desktop-install.log
# shellcheck source=install/cargo.sh
. "$here/cargo.sh"

all=(callers porter stoker almanac docket cua detent casement sill transom turnstile keycap anyview mailo files palmrest session)

# build_part PART: build what PART's installer installs, as you. Parts whose installer builds as you and
# asks for sudo itself (stoker, almanac, docket, cua, sill, mailo, files) build in their install step instead.
build_part() {
  local s=$siblings
  case $1 in
    porter) build_outside "$s/porter" -p accountd -p syncd -p inferd -p porter-mountd -p porter-engines-install ;;
    detent) build_outside "$s/detent" -p detent ;;
    casement) build_outside "$s/casement" -p casement -p casementctl ;;
    transom) build_outside "$s/transom" -p transom ;;
    turnstile) build_outside "$s/turnstile" -p turnstile ;;
    keycap) build_outside "$s/keycap" -p keycap ;;
    palmrest) build_outside "$s/palmrest" -p palmrest ;;
    anyview) build_outside "$s/anyview" -p anyview -p anyview-ffmpeg -p anyview-heif -p anyview-raw ;;
    *) return 0 ;;
  esac
}

# install_part PART: install PART from what was built. As root (sudo) only where the installer wants root
# for the whole run; the rest run as you and use the sudo already granted.
install_part() {
  local s=$siblings p=$prefix d=$desktop
  case $1 in
    callers) sudo "$d/install/system.sh" callers ;;
    porter) sudo "$s/porter/scripts/install.sh" --prefix "$p" --sysconfdir /etc --no-build ;;
    stoker) "$s/stoker/scripts/install.sh" --prefix "$p" --sysconfdir /etc ;;
    almanac) "$s/almanac/scripts/install.sh" --prefix "$p" ;;
    docket) "$s/docket/scripts/install.sh" --prefix "$p" ;;
    cua) "$s/cua/scripts/install.sh" --prefix "$p" ;;
    detent) sudo env PREFIX="$p" "$s/detent/scripts/install.sh" ;;
    casement) sudo "$s/casement/scripts/install.sh" --prefix "$p" --locked --no-build ;;
    sill) "$s/sill/dist/install.sh" ;;
    transom) sudo "$s/transom/scripts/install.sh" --prefix "$p" --no-build ;;
    turnstile | keycap | palmrest) sudo "$d/install/system.sh" "$1" --prefix "$p" --siblings "$s" ;;
    anyview) sudo "$s/anyview/dist/install.sh" --prefix "$p" --no-build ;;
    # Only the prefix: with MAILO_UNIT_DIR set too, mailo takes both for a place you own and never asks
    # for sudo. Its unit goes to its default, /etc/systemd/user.
    mailo) MAILO_PREFIX=$p "$s/mailo/dist/install.sh" ;;
    # Its installer builds as you and asks for sudo itself only when the prefix is not yours.
    files) FILES_PREFIX=$p "$s/files/dist/install.sh" ;;
    session) sudo "$d/install/install.sh" --prefix "$p" --sysconfdir /etc --siblings "$s" ;;
  esac
}

# quietly LABEL CMD...: one line for the step, the output to the log.
quietly() {
  local label=$1
  shift
  printf '  %-10s %s… ' "$label" "$verb"
  { echo; echo "=== $label: $verb ($(date -Is))"; } >>"$log"
  if (cd "$siblings" && "$@") >>"$log" 2>&1 </dev/null; then
    echo done
  else
    printf 'FAILED\n\n'
    tail -n 25 "$log" | sed 's/^/    /'
    printf '\n  the whole output is in %s\n' "$log"
    exit 1
  fi
}

mode=${1:?usage: plain.sh build|install [PART...]}
shift
parts=("$@")
[ ${#parts[@]} -gt 0 ] || parts=("${all[@]}")
for part in "${parts[@]}"; do
  case " ${all[*]} " in *" $part "*) ;; *) echo "no part named $part (the parts: ${all[*]})" >&2; exit 2 ;; esac
done
mkdir -p "$(dirname "$log")"
: >"$log"

verb=building
for part in "${parts[@]}"; do
  case $part in porter | detent | casement | transom | turnstile | keycap | palmrest | anyview) quietly "$part" build_part "$part" ;; esac
done
[ "$mode" = install ] || exit 0

echo "  sudo asks for your password once:"
sudo -v
while sleep 50; do sudo -n true 2>/dev/null || exit; done &
keepalive=$!
trap 'kill "$keepalive" 2>/dev/null || true' EXIT
verb=installing
for part in "${parts[@]}"; do quietly "$part" install_part "$part"; done
echo
echo "  installed to $prefix. Log out and back in to \"sill (casement)\" to use it."
