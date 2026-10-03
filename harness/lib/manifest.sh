# Reads ~/desktop/manifest.toml (flat TOML: [protocols] and [repo.<name>] tables of `key = value`).
MANIFEST="${MANIFEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/manifest.toml}"

manifest_repos() { sed -n 's/^\[repo\.\(.*\)\]$/\1/p' "$MANIFEST"; }

# manifest_get TABLE KEY: the value of KEY in [TABLE] (quotes stripped); empty when absent.
manifest_get() {
  awk -v sec="[$1]" -v key="$2" '
    $0 == sec { on = 1; next }
    /^\[/ { on = 0 }
    on && $1 == key { sub(/^[^=]*=[ \t]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$MANIFEST"
}

manifest_repo_get() { manifest_get "repo.$1" "$2"; }
