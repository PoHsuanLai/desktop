#!/usr/bin/env bash
# Does the manifest hold together, and does every consumer's Cargo.lock agree with it?
#
#   manifest-check.sh [--syntax] [--repos-dir DIR]
#
# --syntax        only the manifest's own shape (no repo is read)
# --repos-dir     where the manifest repos live (default $HOME); locks are read from git at each
#                 repo's manifest rev (`git show <rev>:<path>`), so no checkout is needed
#
# Shape: [protocols] casement_protocols, keycap, palmrest are integers; every [repo.<name>] has
# url, rev (40 hex), branch, gate (lane|none).
# Agreement: in every Cargo.lock of every repo (at its rev), a package sourced from
# git+<url of a manifest repo> must be locked at that repo's manifest rev. Path dependencies leave
# no trace in a lock and are covered by the gate building every repo at its rev side by side.
# Exit 0 pass, 1 a disagreement or a malformed manifest.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../harness/lib/manifest.sh
source "$HERE/../harness/lib/manifest.sh"
syntax_only=0 repos_dir="$HOME"
while [ $# -gt 0 ]; do
  case "$1" in
    --syntax) syntax_only=1; shift ;;
    --repos-dir) repos_dir=$2; shift 2 ;;
    *) echo "usage: manifest-check.sh [--syntax] [--repos-dir DIR]" >&2; exit 64 ;;
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

if [ "$syntax_only" = 0 ] && [ "$bad" = 0 ]; then
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

if [ "$bad" = 0 ]; then echo "manifest-check: ok ($(wc -w <<<"$repos") repos)"; else echo "manifest-check: $bad problem(s)"; exit 1; fi
