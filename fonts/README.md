# fonts

`Noto-COLRv1.ttf` is Noto Color Emoji in the COLRv1 build, the only colour emoji format our renderer can
draw. Fedora ships it as `google-noto-color-emoji-fonts`; Ubuntu (`fonts-noto-color-emoji`) and Arch
(`noto-fonts-emoji`) ship the bitmap build, which draws nothing for us. `install.sh` puts this file in
`<prefix>/share/fonts/quire/` unless fontconfig already lists a `Noto-COLRv1` font.

| File | Source | sha256 |
|---|---|---|
| `Noto-COLRv1.ttf` | `https://raw.githubusercontent.com/googlefonts/noto-emoji/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/2D/fonts/Noto-COLRv1.ttf` (googlefonts/noto-emoji, `2D/fonts/`, main as of 2026-10-16) | `b8e25ea68db82f9e4d0aee921f4420be2be39887bd5c893a2ad98710531f9d0c` |
| `OFL.txt` | `https://raw.githubusercontent.com/googlefonts/noto-emoji/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/2D/fonts/LICENSE` | `6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2` |

The font file is byte-identical to Fedora's `/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf`
(same sha256). Licence: SIL Open Font License 1.1 (`OFL.txt`), which allows shipping the font with software as
long as the font is not sold by itself.

To update: download the new file from the same path at a new commit, replace both rows above, and check
`sha256sum fonts/*`.
