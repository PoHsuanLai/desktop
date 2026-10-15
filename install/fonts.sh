# shellcheck shell=bash
# The colour emoji font (sourced by install.sh, never run). Our renderer draws only COLRv1 colour fonts. Fedora's
# google-noto-color-emoji-fonts is one; Ubuntu's fonts-noto-color-emoji and Arch's noto-fonts-emoji are the bitmap
# build, which draws nothing for us. So the desktop ships Noto-COLRv1.ttf (OFL, see fonts/README.md) and puts it
# in <prefix>/share/fonts/quire/ unless fontconfig already knows a COLRv1 Noto Color Emoji.
#
# Needs from the caller: HERE (the desktop repo), prefix, destdir. DESKTOP_FONTS_SRC overrides the directory the
# font comes from (tests).
#
#   emoji_font_dir        where it goes (without the destdir)
#   emoji_font_state      installed (our copy is there and current) | present (fontconfig already has a COLRv1
#                         Noto Color Emoji; not asked for a staged install) | wanted
#   install_emoji_font    copy the font and its licence, then `fc-cache -f` the directory (not when staged)
#   emoji_font_commands   the commands, as root would run them, for when the directory is not writable by you

emoji_font_src() { echo "${DESKTOP_FONTS_SRC:-$HERE/fonts}"; }
emoji_font_dir() { echo "$prefix/share/fonts/quire"; }

emoji_font_state() {
  local target=$destdir$(emoji_font_dir)/Noto-COLRv1.ttf listing
  if [ -f "$target" ]; then
    if cmp -s "$target" "$(emoji_font_src)/Noto-COLRv1.ttf"; then echo installed; else echo wanted; fi
    return 0
  fi
  if [ -z "$destdir" ] && command -v fc-list >/dev/null; then
    listing=$(fc-list 2>/dev/null || true)
    case "$listing" in *Noto-COLRv1*) echo present; return 0 ;; esac
  fi
  echo wanted
}

install_emoji_font() {
  local src dir
  src=$(emoji_font_src)
  dir=$destdir$(emoji_font_dir)
  install -d "$dir"
  install -m 644 "$src/Noto-COLRv1.ttf" "$dir/Noto-COLRv1.ttf"
  install -m 644 "$src/OFL.txt" "$dir/OFL-Noto-COLRv1.txt"
  if [ -z "$destdir" ] && command -v fc-cache >/dev/null; then fc-cache -f "$dir" || echo "install.sh: fc-cache failed; log out and in, or run: fc-cache -f $dir" >&2; fi
}

emoji_font_commands() {
  local src dir
  src=$(emoji_font_src)
  dir=$(emoji_font_dir)
  as_root_hint install -d "$dir"
  as_root_hint install -m 644 "$src/Noto-COLRv1.ttf" "$dir/Noto-COLRv1.ttf"
  as_root_hint install -m 644 "$src/OFL.txt" "$dir/OFL-Noto-COLRv1.txt"
  as_root_hint fc-cache -f "$dir"
}
