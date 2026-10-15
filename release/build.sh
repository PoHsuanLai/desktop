#!/usr/bin/env bash
# Build the components at their manifest revs and stage them for a release bundle.
#
#   release/build.sh --version X [--out DIR] [--siblings DIR] [--only NAME[,NAME]]
#
#   --version X     the release version (recorded in OUT/version; pack.sh takes it again)
#   --out DIR       default build/release under this repo. Gets stage/ (the destdir), target/<repo>/ (cargo's
#                   output, cacheable) and components.d/<name>.txt ("repo rev" lines for pack.sh)
#   --siblings DIR  where the component repos are checked out side by side (default: the parent of this repo)
#   --only NAMES    just these (casement sill session porter detent keycap palmrest anyview mailo slipway); the
#                   CI builds the heavy ones in separate jobs and merges the stage/ trees
#
# Everything is built with `cargo build --release --locked` and installed with the prefix
# /opt/quire/current under the destdir OUT/stage, through the component's own installer where it can stage
# (porter, detent, anyview, mailo, and the session in install/). The others (casement, sill, keycap, palmrest,
# slipway) have an installer that cannot stage without sudo or writes $HOME; their staging below is marked
# INTERIM and listed in FINDINGS.md with what each installer must learn. Each sibling must be checked out at
# its manifest rev (RELEASE_ALLOW_DIRTY_REVS=1 skips that check, for a trial on a working tree).
# A component whose repo is not beside this one is an error, except slipway (not in the manifest yet) and
# the mpv-wgpu plugin of anyview, which are left out with a warning.
# Exit: 0 staged, 1 a build or install failed, 2 bad usage or a checkout at the wrong rev.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
P=/opt/quire/current
ALL=(casement sill session porter detent keycap palmrest anyview mailo slipway)

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
  (cd "$dir" && CARGO_TARGET_DIR="${CARGO_TARGET_ROOT:-$out/target}/$name" cargo build --release --locked "$@")
}
tdir() { printf '%s/%s/release' "${CARGO_TARGET_ROOT:-$out/target}" "$1"; }

# put MODE SRC REL: install SRC at $root/REL.
put() { install -Dm"$1" "$2" "$root/$3"; }
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
  # service and the keycap layer have no exportable home, so they sit under share/sill for the updater's
  # system step (FINDINGS.md).
  put 755 "$(tdir sill)/sill" bin/sill
  put 644 "$d/dist/intents/org.quire.Shell.toml" share/quire/intents/org.quire.Shell.toml
  (cd "$d/dist/skills" && find . -type f | sort) | while IFS= read -r f; do
    put 644 "$d/dist/skills/$f" "share/quire/skills/${f#./}"
  done
  local schema; schema=$(mktemp -d)
  "$(tdir sill)/sill" --write-schema "$schema" >/dev/null
  put 644 "$schema/sill.settings.toml" share/quire/settings/sill.settings.toml
  rm -rf "$schema"
  put 644 "$d/dist/pam.d/sill" share/sill/pam.d/sill
  put 644 "$d/dist/keycap/keycap.toml" share/sill/keycap.toml
}

build_session() {
  echo "desktop $(git -C "$ROOT" rev-parse HEAD)" >"$out/components.d/desktop.txt"
  # The unit is casement's (staged by its component); the sessions entry lands in the exported directory,
  # the user target in lib/systemd/user (this installer puts it under <sysconfdir>/systemd/user).
  CASEMENT_UNIT_FILE=/nonexistent "$ROOT/install/install.sh" --prefix "$P" --destdir "$stage" \
    --sysconfdir "$P/lib" --sessions-dir "$P/share/wayland-sessions"
}

build_porter() {
  local d; d=$(repo_dir porter)
  cargo_in "$d" porter -p accountd -p syncd -p inferd
  # --sysconfdir under the prefix: the caller table lands at etc/porter/callers.toml (FINDINGS.md: where it is read).
  (cd "$d" && CARGO_TARGET_DIR="${CARGO_TARGET_ROOT:-$out/target}/porter" \
    ./scripts/install.sh --no-build --prefix "$P" --destdir "$stage" --sysconfdir "$P/etc")
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

build_keycap() {
  local d; d=$(repo_dir keycap)
  cargo_in "$d" keycap
  # INTERIM: install.sh stages under DESTDIR but at /etc and /usr/local, outside the prefix. System files
  # (unit, udev, polkit rules) sit under share/keycap for the updater's system step.
  put 755 "$(tdir keycap)/keycap" bin/keycap
  put 644 "$d/dist/keycap.service" share/keycap/keycap.service
  retarget "$root/share/keycap/keycap.service" /usr/local/bin/keycap
  put 644 "$d/dist/70-keycap.rules" share/keycap/70-keycap.rules
  put 644 "$d/dist/keycap.polkit.rules" share/keycap/keycap.polkit.rules
  put 644 "$d/dist/keycap.plasma.toml" share/keycap/keycap.plasma.toml
}

build_palmrest() {
  local d; d=$(repo_dir palmrest)
  cargo_in "$d" palmrest
  # INTERIM: install.sh writes ~/.local/bin and the user's systemd directory and enables the service.
  put 755 "$(tdir palmrest)/palmrest" bin/palmrest
  put 644 "$d/dist/palmrest.service" lib/systemd/user/palmrest.service
  retarget "$root/lib/systemd/user/palmrest.service" '%h/.local/bin/palmrest'
  put 644 "$d/dist/70-palmrest.rules" share/palmrest/70-palmrest.rules
  put 644 "$d/dist/99-palmrest.conf" share/palmrest/99-palmrest.conf
}

build_slipway() {
  if [ ! -d "$sib/slipway" ]; then echo "build.sh: WARNING: no slipway checkout: it is left out of this release" >&2; return 0; fi
  local d; d=$(repo_dir slipway)
  cargo_in "$d" slipway -p slipway
  # INTERIM: slipway has no installer yet; its dist/ (units, polkit action) is installed by it when it does.
  put 755 "$(tdir slipway)/slipway" bin/slipway
  put 755 "$(tdir slipway)/slipway-apply" libexec/slipway-apply
  if [ -d "$d/dist" ]; then
    (cd "$d/dist" && find . -type f | sort) | while IFS= read -r f; do put 644 "$d/dist/$f" "share/slipway/dist/${f#./}"; done
  fi
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
