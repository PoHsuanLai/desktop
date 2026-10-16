#!/usr/bin/env bash
# Build the components at their manifest revs and stage them for a release bundle.
#
#   release/build.sh --version X [--out DIR] [--siblings DIR] [--only NAME[,NAME]]
#
#   --version X     the release version (recorded in OUT/version; pack.sh takes it again)
#   --out DIR       default build/release under this repo. Gets stage/ (the destdir), target/<repo>/ (cargo's
#                   output, cacheable) and components.d/<name>.txt ("repo rev" lines for pack.sh)
#   --siblings DIR  where the component repos are checked out side by side (default: the parent of this repo)
#   --only NAMES    just these (casement sill session porter detent transom keycap palmrest anyview mailo slipway); the
#                   CI builds the heavy ones in separate jobs and merges the stage/ trees
#
# Everything is built with `cargo build --release --locked` and installed with the prefix
# /opt/quire/current under the destdir OUT/stage, through the component's own installer where it can stage
# (porter, detent, anyview, mailo, and the session in install/). The others (casement, sill, transom, keycap,
# palmrest, slipway) have an installer that cannot stage without sudo or writes $HOME; their staging below is marked
# INTERIM and listed in FINDINGS.md with what each installer must learn. Each sibling must be checked out at
# its manifest rev (RELEASE_ALLOW_DIRTY_REVS=1 skips that check, for a trial on a working tree).
# A component whose repo is not beside this one is an error, except the mpv-wgpu plugin of anyview, which is
# left out with a warning.
# Builds use this system's own linker: install/cargo.sh runs cargo from / with --manifest-path, so a tree's
# .cargo/config.toml (clang and mold, for development) is not read.
# Exit: 0 staged, 1 a build or install failed, 2 bad usage or a checkout at the wrong rev.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
P=/opt/quire/current
# shellcheck source=../install/cargo.sh
source "$ROOT/install/cargo.sh"
ALL=(casement sill session porter detent transom keycap palmrest anyview mailo slipway)

version="" out="$ROOT/build/release" sib="$(dirname "$ROOT")" only=""
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "build.sh: $*" >&2; exit "${2:-1}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version=${2:?}; shift ;;
    --out) out=${2:?}; shift ;;
    --siblings) sib=${2:?}; shift ;;
    --only) only=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument $1" 2 ;;
  esac
  shift
done
[ -n "$version" ] || { usage >&2; die "--version is required" 2; }
mkdir -p "$out"; out=$(cd "$out" && pwd); sib=$(cd "$sib" && pwd)
stage="$out/stage"; root="$stage$P"
mkdir -p "$root" "$out/components.d"
printf '%s\n' "$version" >"$out/version"

selected=("${ALL[@]}")
if [ -n "$only" ]; then
  selected=()
  for n in ${only//,/ }; do
    case " ${ALL[*]} " in *" $n "*) selected+=("$n") ;; *) die "no component named $n (known: ${ALL[*]})" 2 ;; esac
  done
fi

manifest_rev() { # REPO: its rev in manifest.toml (empty when not listed)
  awk -v r="[repo.$1]" '$0 == r { f = 1; next } /^\[/ { f = 0 } f && $1 == "rev" { gsub(/"/, "", $3); print $3 }' "$ROOT/manifest.toml"
}

# repo_dir REPO: the checkout, at the manifest rev; records "repo rev" for pack.sh.
repo_dir() {
  local repo=$1 dir="$sib/$1" want have
  [ -d "$dir" ] || die "$repo: no checkout at $dir (--siblings says where the repos are)" 2
  have=$(git -C "$dir" rev-parse HEAD)
  want=$(manifest_rev "$repo")
  if [ -n "$want" ] && [ "$have" != "$want" ] && [ -z "${RELEASE_ALLOW_DIRTY_REVS:-}" ]; then
    die "$repo is at $have, the manifest pins $want" 2
  fi
  echo "$repo $have" >"$out/components.d/$repo.txt"
  printf '%s' "$dir"
}

# cargo_in DIR TARGETNAME ARGS...: a locked release build with its own target directory.
cargo_in() {
  local dir=$1 name=$2; shift 2
  echo "== cargo build --release --locked $* ($name)"
  (export CARGO_TARGET_DIR="${CARGO_TARGET_ROOT:-$out/target}/$name"; build_outside "$dir" "$@")
}
tdir() { printf '%s/%s/release' "${CARGO_TARGET_ROOT:-$out/target}" "$1"; }

# put MODE SRC REL: install SRC at $root/REL.
put() { install -Dm"$1" "$2" "$root/$3"; }
# put_system MODE SRC DEST: a file slipway-apply copies (as root) to the absolute DEST on the computer. It
# travels in the bundle at system/DEST and pack.sh lists it; DEST must sit directly in one of the system
# folders release.py (and slipway) allow: a mistake here is refused when the release is packed.
put_system() { put "$1" "$2" "system$3"; }
# retarget FILE FROM: the unit's path to its program becomes the installed one.
retarget() { sed -i "s|^ExecStart=$2|ExecStart=$P/bin/$(basename "$2")|" "$1"; grep -q "^ExecStart=$P/bin/" "$1" || die "$1: no ExecStart to retarget"; }

build_casement() {
  local d; d=$(repo_dir casement)
  cargo_in "$d" casement -p casement -p casementctl
  # INTERIM: casement has no installer; it ships dist/casement.service with ExecStart=/usr/bin/casement.
  put 755 "$(tdir casement)/casement" bin/casement
  put 755 "$(tdir casement)/casementctl" bin/casementctl
  put 644 "$d/dist/casement.service" lib/systemd/user/casement.service
  retarget "$root/lib/systemd/user/casement.service" /usr/bin/casement
}

build_sill() {
  local d; d=$(repo_dir sill)
  cargo_in "$d" sill -p sill
  # INTERIM: dist/install.sh has fixed destinations and sudo. Same files, under the prefix; the PAM
  # service is a system file (slipway-apply places it), and the keycap layer sits under share/sill
  # (FINDINGS.md).
  put 755 "$(tdir sill)/sill" bin/sill
  put 644 "$d/dist/intents/org.quire.Shell.toml" share/quire/intents/org.quire.Shell.toml
  (cd "$d/dist/skills" && find . -type f | sort) | while IFS= read -r f; do
    put 644 "$d/dist/skills/$f" "share/quire/skills/${f#./}"
  done
  local schema; schema=$(mktemp -d)
  "$(tdir sill)/sill" --write-schema "$schema" >/dev/null
  put 644 "$schema/sill.settings.toml" share/quire/settings/sill.settings.toml
  rm -rf "$schema"
  put_system 644 "$d/dist/pam.d/sill" /etc/pam.d/sill
  # External-monitor brightness (distro audit D7): the uaccess rule for the i2c buses and the list that loads
  # i2c-dev. Both folders are on slipway's list of system folders. Fedora's ddcutil package ships a rule with the
  # same tag; two rules with the same tag are harmless, so the install.sh "unless ddcutil has it" test is not needed.
  put_system 644 "$d/dist/udev/60-sill-ddc.rules" /etc/udev/rules.d/60-sill-ddc.rules
  put_system 644 "$d/dist/modules-load.d/sill-ddc.conf" /etc/modules-load.d/sill-ddc.conf
  put 644 "$d/dist/keycap/keycap.toml" share/sill/keycap.toml
}

build_session() {
  echo "desktop $(git -C "$ROOT" rev-parse HEAD)" >"$out/components.d/desktop.txt"
  # The unit is casement's (staged by its component); the sessions entry lands in the exported directory,
  # the user target in lib/systemd/user (this installer puts it under <sysconfdir>/systemd/user).
  CASEMENT_UNIT_FILE=/nonexistent "$ROOT/install/install.sh" --prefix "$P" --destdir "$stage" \
    --sysconfdir "$P/lib" --sessions-dir "$P/share/wayland-sessions"
  # The colour emoji font (install.sh puts the same two files in <prefix>/share/fonts/quire/): ubuntu and arch ship
  # a bitmap build our renderer cannot draw. share/fonts is exported to /usr/share/fonts, where quire's search
  # (ds-blitz emoji_file.rs: <data dir>/fonts/quire/Noto-COLRv1.ttf for each XDG data dir, /usr/share included) finds it.
  put 644 "$ROOT/fonts/Noto-COLRv1.ttf" share/fonts/quire/Noto-COLRv1.ttf
  put 644 "$ROOT/fonts/OFL.txt" share/fonts/quire/OFL-Noto-COLRv1.txt
}

build_porter() {
  local d; d=$(repo_dir porter)
  cargo_in "$d" porter -p accountd -p syncd -p inferd
  # --sysconfdir under the bundle's system tree: the caller table lands at system/etc/porter/callers.toml, a
  # system file slipway-apply places at /etc/porter/callers.toml (where porter reads it).
  (cd "$d" && CARGO_TARGET_DIR="${CARGO_TARGET_ROOT:-$out/target}/porter" \
    ./scripts/install.sh --no-build --prefix "$P" --destdir "$stage" --sysconfdir "$P/system/etc")
}

build_detent() {
  local d; d=$(repo_dir detent)
  cargo_in "$d" detent
  DETENT_BIN="$(tdir detent)/detent" "$ROOT/install.sh" --siblings "$sib" --prefix "$P" --destdir "$stage" --only detent
}

build_anyview() {
  local d t cplugin=() ; d=$(repo_dir anyview); t=$(tdir anyview)
  cargo_in "$d" anyview -p anyview -p anyview-ffmpeg -p anyview-heif -p anyview-raw
  if [ -d "$sib/mpv" ]; then
    local m; m=$(repo_dir mpv)
    cargo_in "$m" mpv -p mpv-wgpu-cplugin
    cplugin=(ANYVIEW_MPV_CPLUGIN="$(tdir mpv)/libmpv_wgpu_cplugin.so")
  else
    echo "build.sh: WARNING: no mpv-wgpu checkout beside the repos: anyview's installer would fetch and build it (unlocked) itself" >&2
  fi
  env ANYVIEW_BIN="$t/anyview" ANYVIEW_FFMPEG_PLUGIN_BIN="$t/anyview-ffmpeg" ANYVIEW_HEIF_PLUGIN_BIN="$t/anyview-heif" \
    ANYVIEW_RAW_PLUGIN_BIN="$t/anyview-raw" "${cplugin[@]}" \
    "$ROOT/install.sh" --siblings "$sib" --prefix "$P" --destdir "$stage" --only anyview
}

build_mailo() {
  local d; d=$(repo_dir mailo)
  cargo_in "$d" mailo -p mail-app --bin mailo
  (cd "$d" && MAILO_BIN="$(tdir mailo)/mailo" MAILO_PREFIX="$root" MAILO_UNIT_DIR="$root/lib/systemd/user" \
    ./dist/install.sh --no-build)
  # INTERIM: the installer writes the destdir-prefixed path into the D-Bus service file; it must name the
  # installed one (FINDINGS.md).
  sed -i "s|$root|$P|g" "$root/share/dbus-1/services/org.quire.Mail.service"
}

build_transom() {
  local d; d=$(repo_dir transom)
  cargo_in "$d" transom -p transom
  # The portal backend (screen sharing, screenshots). Same files and places as transom's scripts/install.sh,
  # under the prefix: the program in libexec, the user unit in lib/systemd/user, the D-Bus activation file
  # and the portal file in the exported share directories (pack.sh links those under /usr). Both the unit and
  # the activation file name /usr/libexec/transom; they must name the installed program. The routing file
  # (quire-portals.conf) is the session's, staged by the session component.
  put 755 "$(tdir transom)/transom" libexec/transom
  put 644 "$d/dist/transom.service" lib/systemd/user/transom.service
  put 644 "$d/dist/org.freedesktop.impl.portal.desktop.quire.service" \
    share/dbus-1/services/org.freedesktop.impl.portal.desktop.quire.service
  put 644 "$d/dist/quire.portal" share/xdg-desktop-portal/portals/quire.portal
  local f
  for f in lib/systemd/user/transom.service share/dbus-1/services/org.freedesktop.impl.portal.desktop.quire.service; do
    sed -i "s|/usr/libexec/transom|$P/libexec/transom|g" "$root/$f"
    grep -q "$P/libexec/transom" "$root/$f" || die "$f: no /usr/libexec/transom to retarget"
  done
}

build_keycap() {
  local d; d=$(repo_dir keycap)
  cargo_in "$d" keycap
  # INTERIM: install.sh stages under DESTDIR but at /etc and /usr/local, outside the prefix. The unit, the
  # udev rule, the polkit rule and the module list are system files (slipway-apply places them); the unit
  # goes to /usr/lib/systemd/system (the vendor folder; /etc stays the administrator's). keycap ships no
  # modules-load file (distro audit lane 12 asks for one): the line is written here.
  put 755 "$(tdir keycap)/keycap" bin/keycap
  put_system 644 "$d/dist/keycap.service" /usr/lib/systemd/system/keycap.service
  retarget "$root/system/usr/lib/systemd/system/keycap.service" /usr/local/bin/keycap
  put_system 644 "$d/dist/70-keycap.rules" /etc/udev/rules.d/70-keycap.rules
  put_system 644 "$d/dist/keycap.polkit.rules" /etc/polkit-1/rules.d/keycap.polkit.rules
  local modules; modules=$(mktemp)
  printf '# keycap writes its virtual keyboard through /dev/uinput.\nuinput\n' >"$modules"
  put_system 644 "$modules" /etc/modules-load.d/keycap.conf
  rm -f "$modules"
  put 644 "$d/dist/keycap.plasma.toml" share/keycap/keycap.plasma.toml
}

build_palmrest() {
  local d; d=$(repo_dir palmrest)
  cargo_in "$d" palmrest
  # INTERIM: install.sh writes ~/.local/bin and the user's systemd directory and enables the service.
  put 755 "$(tdir palmrest)/palmrest" bin/palmrest
  put 644 "$d/dist/palmrest.service" lib/systemd/user/palmrest.service
  retarget "$root/lib/systemd/user/palmrest.service" '%h/.local/bin/palmrest'
  put_system 644 "$d/dist/70-palmrest.rules" /etc/udev/rules.d/70-palmrest.rules
  put_system 644 "$d/dist/99-palmrest.conf" /etc/modprobe.d/99-palmrest.conf
}

build_slipway() {
  local d; d=$(repo_dir slipway)
  cargo_in "$d" slipway -p slipway
  # INTERIM: slipway's scripts/install.sh installs the helper, polkit action, unit and bus file on a machine
  # (first install, release/bootstrap.sh); the release carries only the user program. slipway-apply is not in
  # the bundle: a release must not replace a binary that runs as root.
  put 755 "$(tdir slipway)/slipway" bin/slipway
}

for name in "${selected[@]}"; do
  echo "=== $name"
  "build_$name"
done

# Nothing may land outside the prefix, and the bundle has no links.
stray=$(cd "$stage" && find . -mindepth 1 -not -path "./opt" -not -path "./opt/quire" -not -path "./opt/quire/current*" | head -n 3)
[ -z "$stray" ] || die "files outside $P: $stray"
links=$(find "$stage" -type l | head -n 3)
[ -z "$links" ] || die "symlinks in the stage (the bundle has none): $links"
echo "build.sh: staged ${selected[*]} in $stage"
