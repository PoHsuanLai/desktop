# Building a component tree for an install or a release (sourced, never run). Always with this system's own
# linker: we never ask the person for one, and we never install one.
#
# Several trees (quire, sill, shell-host, detent, porter) have a .cargo/config.toml that links with clang and
# mold, which is how they are worked on. Cargo reads that file, and rustup reads rust-toolchain.toml, from the
# directory cargo runs in, never from the manifest's. So a build runs from / with the tree named by
# --manifest-path, the pinned toolchain goes on in RUSTUP_TOOLCHAIN, and the one setting an install wants from
# that file is given again. No RUSTFLAGS. The target directory is explicit.
#
#   build_outside DIR CARGO-ARGS...   cargo build --release --locked of DIR's manifest, run from /;
#                                     CARGO_TARGET_DIR if set, else DIR/target

# tree_toolchain DIR: the channel DIR/rust-toolchain.toml pins (empty when it pins none).
tree_toolchain() {
  sed -n 's/^channel *= *"\(.*\)"/\1/p' "$1/rust-toolchain.toml" 2>/dev/null | head -n 1
}

# tree_configs DIR: the --config arguments the tree's .cargo/config.toml gives besides the linker and the
# rustflags, one per line. The table is by tree name: add a line when a tree's config grows a setting a build
# needs.
tree_configs() {
  case "$(basename "$1")" in
    quire | sill | shell-host | detent | porter | almanac) echo "net.git-fetch-with-cli=true" ;;
  esac
}

build_outside() {
  local dir=$1 toolchain cfg configs=()
  shift
  toolchain=$(tree_toolchain "$dir")
  while IFS= read -r cfg; do [ -z "$cfg" ] || configs+=(--config "$cfg"); done < <(tree_configs "$dir")
  (
    cd / || exit 1
    if [ -n "$toolchain" ] && command -v rustup >/dev/null 2>&1; then export RUSTUP_TOOLCHAIN=$toolchain; fi
    export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$dir/target}"
    cargo build --release --locked --manifest-path "$dir/Cargo.toml" "${configs[@]}" "$@"
  )
}
