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
#   --fabricate-gpus N   fabricate N soft GPU nodes: /sys/dev/char/226:(200+n)/device/drm, n < N,
#                        and hide every real /sys/dev/char entry (drm_node from_dev_id only stats it)
#   --env K=V            set one more variable inside (the environment is otherwise cleared)
#   --net-none           accepted and implied: the network namespace is always unshared
#
# Beyond the plan's command line: `--proc /proc` (so PID 1 of the namespace, bwrap, is visible
# to require_jail, and the host's processes are not), and PATH, LANG, TERM carried in.
#
# Exit codes (plan §6.1): the command's own; 3 = bubblewrap or /dev/udmabuf or a --bind dir missing.
set -euo pipefail

binds=() envs=() gpus=0 scratch="" own_scratch=0
die3() { echo "jail: $1" >&2; echo "jail: fix: $2" >&2; exit 3; }
usage() { sed -n '2,20p' "$0" >&2; exit 64; }

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
[ "$gpus" -le 55 ] || usage   # minors 200..255

command -v bwrap >/dev/null || die3 "bubblewrap (bwrap) not found" "sudo dnf install bubblewrap"
[ -c /dev/udmabuf ] || die3 "/dev/udmabuf is missing" "log in locally (it needs a uaccess ACL) or run: sudo modprobe udmabuf"

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
  --tmpfs /sys/dev/char
)
n=0
while [ "$n" -lt "$gpus" ]; do
  args+=(--dir "/sys/dev/char/226:$((200 + n))/device/drm")
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
  --setenv PATH "$PATH" --setenv LANG "${LANG:-C.UTF-8}" --setenv TERM "${TERM:-dumb}"
  --setenv HOME "$scratch/home" --setenv XDG_RUNTIME_DIR "/run/user/$uid"
  --setenv XDG_CONFIG_HOME "$scratch/config" --setenv XDG_STATE_HOME "$scratch/state"
  --setenv XDG_CACHE_HOME "$scratch/cache"
  --setenv __EGL_VENDOR_LIBRARY_FILENAMES /usr/share/glvnd/egl_vendor.d/50_mesa.json
  --setenv VK_ICD_FILENAMES /usr/share/vulkan/icd.d/lvp_icd.x86_64.json
  --setenv MESA_SHADER_CACHE_DISABLE true --setenv LP_NUM_THREADS 4
  --setenv JAIL_SCRATCH "$scratch" --setenv JAIL_GPUS "$gpus"
)
for kv in "${envs[@]}"; do args+=(--setenv "${kv%%=*}" "${kv#*=}"); done

# Not `exec`: the EXIT trap removes a temporary scratch dir.
set +e
bwrap "${args[@]}" -- "$@"
rc=$?
exit "$rc"
