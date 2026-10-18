#!/usr/bin/env bash
# Builds the drawing app W2 uses: Excalidraw (MIT) as one offline page, no account, no network at run time.
#
#   build-excalidraw.sh [OUT]     OUT defaults to ${XDG_CACHE_HOME:-~/.cache}/quire-workflow/excalidraw-0.18.0
#
# Versions are pinned. Packages are fetched into a folder of their own with install scripts off, and the
# bundler is run from there with this folder's sources passed by path. Needs node and npm; changes nothing
# outside OUT and its own build folder. Safe to repeat: an OUT that already has main.js is left alone.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-${XDG_CACHE_HOME:-$HOME/.cache}/quire-workflow/excalidraw-0.18.0}
[ -s "$OUT/main.js" ] && { echo "already built: $OUT"; exit 0; }
command -v npm >/dev/null || { echo "build-excalidraw.sh: needs node and npm" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/w2-excalidraw.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && npm init -y >/dev/null \
  && npm install --ignore-scripts --no-audit --no-fund \
       @excalidraw/excalidraw@0.18.0 react@19.1.0 react-dom@19.1.0 esbuild@0.25.5 >/dev/null )
mkdir -p "$OUT"
NODE_PATH="$WORK/node_modules" "$WORK/node_modules/.bin/esbuild" "$HERE/main.jsx" --bundle --minify \
  --format=iife --jsx=automatic --conditions=production --define:process.env.NODE_ENV='"production"' \
  --loader:.woff2=file --loader:.ttf=file --log-level=warning --outdir="$OUT"
cp "$HERE/index.html" "$OUT/"
cp -r "$WORK/node_modules/@excalidraw/excalidraw/dist/prod/fonts" "$OUT/"
echo "built: $OUT"
