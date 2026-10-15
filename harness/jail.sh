#!/usr/bin/env bash
# The one jail (casement-scope 11 §1.2, freeze plan §6.1).
#
#   jail.sh [--bind DIR]... [--scratch DIR] [--fabricate-gpus N] [--env K=V]... [--net-none] -- CMD...
#
# An unprivileged bubblewrap namespace: the host filesystem read-only, a private /dev (no input,
# dri, uinput, hidraw; only /dev/udmabuf), an empty /run, a tmpfs /tmp, no network, a new PID
# namespace that dies with its parent, a scratch HOME and XDG dirs. Safety rests on that
# structure, not on scripts behaving well. This machine's user is in the `input` group.
#
#   --bind DIR           make DIR writable inside (the lane's worktree, its cargo target dir)
#   --scratch DIR        use DIR (created) as scratch instead of a fresh temporary one, which is
#                        removed on exit; HOME, XDG_CONFIG/STATE/CACHE_HOME live under it
#   --fabricate-gpus N   fabricate N soft GPU nodes (N <= 64): /sys/dev/char/226:(128+n)/device/drm,
#                        n < N, and hide every real /sys/dev/char entry. The minors are in the render
#                        range because the drm crate (0.14, DrmNode::from_dev_id) types a node by
#                        `minor >> 6` and rejects 192..255 as "not a DRM node"; hiding the real
#                        entries means renderD128 cannot collide
#   --env K=V            set one more variable inside (the environment is otherwise cleared)
#   --net-none           accepted and implied: the network namespace is always unshared
#
# Beyond the plan's command line: `--proc /proc` (so PID 1 of the namespace, bwrap, is visible
# to require_jail, and the host's processes are not), and PATH, USER, LANG, TERM carried in.
#
# Exit codes (plan §6.1): the command's own; 3 = bubblewrap or /dev/udmabuf or a --bind dir missing, or the
# system forbids the namespace (Ubuntu 24.04's AppArmor rule), or the software Vulkan driver is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install/distro.sh
source "$ROOT/install/distro.sh"
# shellcheck source=../install/packages.sh
source "$ROOT/install/packages.sh"

binds=() envs=() gpus=0 scratch="" own_scratch=0
die3() { echo "jail: $1" >&2; echo "jail: fix: $2" >&2; exit 3; }
usage() { sed -n '2,24p' "$0" >&2; exit 64; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bind) [ $# -ge 2 ] || usage; binds+=("$2"); shift 2 ;;
    --scratch) [ $# -ge 2 ] || usage; scratch="$2"; shift 2 ;;
    --fabricate-gpus) [ $# -ge 2 ] || usage; gpus="$2"; shift 2 ;;
    --env) [ $# -ge 2 ] || usage; envs+=("$2"); shift 2 ;;
    --net-none) shift ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ $# -gt 0 ] || usage
case "$gpus" in ''|*[!0-9]*) usage ;; esac
[ "$gpus" -le 64 ] || usage   # render minors 128..191 (drm crate: minor >> 6 == 2)

# hint_line KEY...: the install line(s) for this machine's family, on one line.
hint_line() { install_hint "$@" | tr '\n' ' '; }

# udmabuf_fix: what to do about a missing /dev/udmabuf. Fedora's logind gives a local login access to it; the
# other families need the module loaded and, if the device is not yours, a udev rule for the seat's user.
udmabuf_fix() {
  local load
  load=$(as_root_hint modprobe udmabuf)
  case "$(distro_family)" in
    fedora) echo "log in locally (it needs a uaccess ACL) or run: $load" ;;
    *) echo "run: $load ; if the device is then not writable by you, add a udev rule KERNEL==\"udmabuf\", TAG+=\"uaccess\" (and udmabuf to /etc/modules-load.d/ to keep it)" ;;
  esac
}

# apparmor_userns_remedy: bubblewrap cannot make a user namespace because Ubuntu 24.04 restricts them.
apparmor_userns_remedy() {
  cat >&2 <<REMEDY
jail: this system lets only programs with an AppArmor profile create user namespaces
jail: (kernel.apparmor_restrict_unprivileged_userns=1, the Ubuntu 24.04 default), and bwrap has none.
jail: fix, either turn the restriction off:
jail:   $(as_root_hint sysctl -w kernel.apparmor_restrict_unprivileged_userns=0)
jail:   (to keep it after a reboot, put that setting in a file under /etc/sysctl.d/)
jail: or give bwrap a profile that allows it: save as /etc/apparmor.d/bwrap
jail:   abi <abi/4.0>,
jail:   include <tunables/global>
jail:   profile bwrap /usr/bin/bwrap flags=(unconfined) {
jail:     userns,
jail:     include if exists <local/bwrap>
jail:   }
jail: and load it with: $(as_root_hint apparmor_parser -r /etc/apparmor.d/bwrap)
REMEDY
  exit 3
}

# lavapipe_icd: the software Vulkan driver's file, the one for this CPU first (its name differs by distro and
# Mesa version: lvp_icd.x86_64.json, lvp_icd.json ...).
lavapipe_icd() {
  local icd first=""
  for icd in /usr/share/vulkan/icd.d/lvp_icd*.json; do
    [ -e "$icd" ] || continue
    [ -n "$first" ] || first=$icd
    case "$icd" in *"$(uname -m)"*) echo "$icd"; return 0 ;; esac
  done
  [ -z "$first" ] || echo "$first"
}

command -v bwrap >/dev/null || die3 "bubblewrap (bwrap) not found" "$(hint_line bwrap)"
[ -c /dev/udmabuf ] || die3 "/dev/udmabuf is missing" "$(udmabuf_fix)"
if ! bwrap --unshare-all --ro-bind / / true 2>/dev/null; then
  if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true)" = 1 ]; then
    apparmor_userns_remedy
  fi
  die3 "bubblewrap cannot start a namespace here" "run 'bwrap --unshare-all --ro-bind / / true' to see why (user namespaces off, or a container without them)"
fi
vulkan_icd=$(lavapipe_icd)
[ -n "$vulkan_icd" ] || die3 "the software Vulkan driver (lavapipe) is not installed" "$(hint_line lavapipe)"

uid=$(id -u)
if [ -z "$scratch" ]; then
  root="${DESKTOP_JAIL_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/desktop-jail}"
  mkdir -p "$root"
  scratch=$(mktemp -d "$root/run.XXXXXX")
  own_scratch=1
else
  mkdir -p "$scratch"
  scratch=$(cd "$scratch" && pwd)
fi
mkdir -p "$scratch/home" "$scratch/config" "$scratch/state" "$scratch/cache"
cleanup() { if [ "$own_scratch" = 1 ]; then rm -rf "$scratch"; fi; }
trap cleanup EXIT

args=(
  --ro-bind / / --dev /dev --dev-bind /dev/udmabuf /dev/udmabuf --proc /proc
  --tmpfs /run --dir "/run/user/$uid" --tmpfs /tmp
  # /usr/share is a throwaway overlay: a scenario may write what an install ships there (porter's
  # /usr/share/porter/clients.toml, which it trusts and a person's own file cannot widen), and the
  # machine's /usr/share is never touched.
  --overlay-src /usr/share --tmp-overlay /usr/share
  --tmpfs /sys/dev/char
)
n=0
while [ "$n" -lt "$gpus" ]; do
  args+=(--dir "/sys/dev/char/226:$((128 + n))/device/drm")
  n=$((n + 1))
done
args+=(--bind "$scratch" "$scratch")
for d in "${binds[@]}"; do
  [ -d "$d" ] || die3 "--bind $d: no such directory" "create it first (a cargo target dir exists after the first build)"
  d=$(cd "$d" && pwd)
  args+=(--bind "$d" "$d")
done
args+=(
  --unshare-net --unshare-ipc --unshare-pid --die-with-parent --new-session
  --clearenv
  --setenv PATH "$PATH" --setenv USER "${USER:-$(id -un)}" --setenv LANG "${LANG:-C.UTF-8}" --setenv TERM "${TERM:-dumb}"
  --setenv HOME "$scratch/home" --setenv XDG_RUNTIME_DIR "/run/user/$uid"
  --setenv XDG_CONFIG_HOME "$scratch/config" --setenv XDG_STATE_HOME "$scratch/state"
  --setenv XDG_CACHE_HOME "$scratch/cache"
  --setenv __EGL_VENDOR_LIBRARY_FILENAMES /usr/share/glvnd/egl_vendor.d/50_mesa.json
  --setenv VK_ICD_FILENAMES "$vulkan_icd"
  --setenv MESA_SHADER_CACHE_DISABLE true --setenv LP_NUM_THREADS 4
  --setenv JAIL_SCRATCH "$scratch" --setenv JAIL_GPUS "$gpus"
)
for kv in "${envs[@]}"; do args+=(--setenv "${kv%%=*}" "${kv#*=}"); done

# Not `exec`: the EXIT trap removes a temporary scratch dir.
set +e
bwrap "${args[@]}" -- "$@"
rc=$?
exit "$rc"
