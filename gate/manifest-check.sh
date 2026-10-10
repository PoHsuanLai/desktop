#!/usr/bin/env bash
# Does the manifest hold together, and does every consumer's Cargo.lock agree with it?
#
#   manifest-check.sh [--syntax] [--no-resolve] [--repos-dir DIR]
#
# --syntax        only the manifest's own shape (no repo is read)
# --no-resolve    skip the resolution step below (the git-source agreement still runs)
# --repos-dir     where the manifest repos live (default $HOME); locks are read from git at each
#                 repo's manifest rev (`git show <rev>:<path>`), so no checkout is needed
#
# Shape: [protocols] casement_protocols, keycap, palmrest are integers; every [repo.<name>] has
# url, rev (40 hex), branch, gate (lane|none).
# Agreement: in every Cargo.lock of every repo (at its rev), a package sourced from
# git+<url of a manifest repo> must be locked at that repo's manifest rev. Path dependencies leave
# no trace in a lock and are covered by the gate building every repo at its rev side by side.
# Resolution: every repo is exported (`git archive`, read-only on the source repo) at its manifest rev
# into one scratch directory, siblings side by side as the gate lays them out, and every directory
# holding a Cargo.toml next to a Cargo.lock is resolved with `cargo metadata --locked`. A lock that
# does not resolve against the pinned siblings (a path dependency whose own dependencies moved, a
# git pin the lock disagrees with) fails with cargo's own message; that is the drift SP6 found
# between sill's lock and the listed quire rev. Network or the cargo cache is needed for registry
# and git dependencies; nothing is built.
# Exit 0 pass, 1 a disagreement or a malformed manifest.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../harness/lib/manifest.sh
source "$HERE/../harness/lib/manifest.sh"
syntax_only=0 resolve=1 repos_dir="$HOME"
while [ $# -gt 0 ]; do
  case "$1" in
    --syntax) syntax_only=1; shift ;;
    --no-resolve) resolve=0; shift ;;
    --repos-dir) repos_dir=$2; shift 2 ;;
    *) echo "usage: manifest-check.sh [--syntax] [--no-resolve] [--repos-dir DIR]" >&2; exit 64 ;;
  esac
done

bad=0
note() { echo "manifest-check: $*"; bad=$((bad + 1)); }

for key in casement_protocols keycap palmrest; do
  case "$(manifest_get protocols "$key")" in ''|*[!0-9]*) note "[protocols] $key is not an integer" ;; esac
done
repos=$(manifest_repos)
[ -n "$repos" ] || note "no [repo.*] tables"
for r in $repos; do
  url=$(manifest_repo_get "$r" url); rev=$(manifest_repo_get "$r" rev)
  [ -n "$url" ] || note "$r: no url"
  [ -n "$(manifest_repo_get "$r" branch)" ] || note "$r: no branch"
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || note "$r: rev '$rev' is not a 40-hex commit"
  case "$(manifest_repo_get "$r" gate)" in lane|none) ;; *) note "$r: gate must be lane or none" ;; esac
done

norm() { sed -e 's/\.git$//' -e 's#/$##' <<<"$1"; }

shape_bad=$bad
if [ "$syntax_only" = 0 ] && [ "$shape_bad" = 0 ]; then
  declare -A rev_of
  for r in $repos; do rev_of[$(norm "$(manifest_repo_get "$r" url)")]="$r $(manifest_repo_get "$r" rev)"; done
  for r in $repos; do
    rev=$(manifest_repo_get "$r" rev); g="$repos_dir/$r"
    git -C "$g" cat-file -e "$rev^{commit}" 2>/dev/null || { note "$r: rev $rev is not in $g"; continue; }
    for lock in $(git -C "$g" ls-tree -r --name-only "$rev" | grep -E '(^|/)Cargo\.lock$' || true); do
      while read -r src; do
        # git+https://github.com/Org/repo.git?rev=XXXX#<sha>  ->  url, sha
        url=$(norm "${src#git+}"); url=${url%%[?#]*}; sha=${src##*#}
        hit=${rev_of[$(norm "$url")]:-}
        [ -n "$hit" ] || continue
        want=${hit#* }; name=${hit%% *}
        [ "$sha" = "$want" ] || note "$r:$lock locks $name at ${sha:0:9}, the manifest says ${want:0:9}"
      done < <(git -C "$g" show "$rev:$lock" | sed -n 's/^source = "\(git+[^"]*\)"$/\1/p' | sort -u)
    done
  done
fi

# waived <repo> <lock> <rev>: a lock listed in gate/stale-locks.txt for exactly this rev (an example
# or tool lock outside the repo's own gate, stale at a release already pinned). A waiver names one
# rev, so it lapses by itself as soon as the manifest moves the repo on.
waived() {
  local list; list="$(dirname "$0")/stale-locks.txt"
  [ -f "$list" ] || return 1
  grep -v '^#' "$list" | awk -v r="$1" -v l="$2" -v v="$3" '$1 == r && $2 == l && $3 == v { found = 1 } END { exit !found }'
}

# resolve_pinned: export every repo at its rev side by side, then `cargo metadata --locked` in each
# directory that has both a Cargo.toml and a Cargo.lock.
resolve_pinned() {
  local scratch r rev g lock dir out
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/manifest-check.XXXXXX") || { note "no scratch directory"; return; }
  for r in $repos; do
    rev=$(manifest_repo_get "$r" rev); g="$repos_dir/$r"
    git -C "$g" cat-file -e "$rev^{commit}" 2>/dev/null || continue   # already reported above
    mkdir -p "$scratch/$r" && git -C "$g" archive "$rev" | tar -x -C "$scratch/$r" \
      || { note "$r: cannot export $rev"; continue; }
  done
  for r in $repos; do
    [ -d "$scratch/$r" ] || continue
    while read -r lock; do
      dir=$(dirname "$lock")
      [ -f "$scratch/$r/$dir/Cargo.toml" ] || continue
      if out=$(cd "$scratch/$r/$dir" && command cargo metadata --locked --format-version 1 2>&1 >/dev/null); then
        echo "manifest-check: resolves $r:${dir#.}" | sed 's#:$#:/#'
      elif waived "$r" "$lock" "$(manifest_repo_get "$r" rev)"; then
        echo "manifest-check: waived $r:$lock at its pinned rev (gate/stale-locks.txt)"
      else
        note "$r:$lock does not resolve --locked against the pinned siblings: $(grep -m1 -E '^error' <<<"$out" | cut -c1-200)"
        sed -n '1,12p' <<<"$out" | sed 's/^/    /' >&2
      fi
    done < <(cd "$scratch/$r" && find . -name Cargo.lock -not -path '*/target/*' -not -path '*/node_modules/*' | sed 's#^\./##' | sort)
  done
  rm -rf "$scratch"
}
if [ "$syntax_only" = 0 ] && [ "$resolve" = 1 ] && [ "$shape_bad" = 0 ]; then resolve_pinned; fi

if [ "$bad" = 0 ]; then echo "manifest-check: ok ($(wc -w <<<"$repos") repos)"; else echo "manifest-check: $bad problem(s)"; exit 1; fi
