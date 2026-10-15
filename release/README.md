# Releases

A signed binary bundle of the whole desktop, built by GitHub Actions at the revs `manifest.toml` pins and
published to the public repo `PoHsuanLai/desktop-releases` (binaries only; the source repos stay private).
slipway, the updater, reads it.

| File | What |
|---|---|
| `build.sh` | builds each component (`cargo build --release --locked`) and installs it under `/opt/quire/current` into a staging root |
| `pack.sh` | stage -> `release.toml` (digests, modes, components, exports), `bundle.tar.zst` (deterministic), `release.toml.minisig` |
| `verify.sh` | checks a packed release the way slipway will; the CI runs it before publishing |
| `selftest.sh` | packs a fake stage with a throwaway key, verifies it, and checks that hostile releases are refused; a SKIP (exit 2) without minisign; run by `gate/desktop-gate.sh --self` |
| `bootstrap.sh` | first install on a machine: downloads the latest release, verifies it, runs slipway's helper |
| `checkout.sh` | checks out every manifest repo at its rev, side by side (used by the workflow) |
| `exports.toml` | exports beyond the ones derived from the staged tree (`/usr/local/bin` links) |
| `release.pub` | the public key (you commit it once, step 3) |
| `../.github/workflows/release.yml` | the workflow |

## The format (frozen; slipway parses exactly this)

Tag `v<semver>`; assets `release.toml`, `release.toml.minisig`, `bundle.tar.zst`.

`release.toml`: `format = 1`, `version`, `date`, `notes`, `bundle = { name, sha256, size }`, a `[components]`
table (repo -> rev, from `manifest.toml`, plus the repos built that it does not list), one `[[file]]`
(`path`, `sha256`, `mode = 0o755`) per regular file sorted by path, and `[[export]]` (`link`, `target`
relative to `/opt/quire/current`). The bundle is a tar.zst of regular files and directories only (no links),
clean relative paths, owner 0, mtime 0, modes 0644 or 0755. Exports may only go under
`/usr/share/wayland-sessions`, `/usr/share/xdg-desktop-portal`, `/usr/share/dbus-1/services`,
`/usr/lib/systemd/user`, `/usr/share/applications`, `/usr/share/polkit-1/actions` and `/usr/local/bin`; every
file staged under the first six directories (as `share/...` or `lib/systemd/user`) is exported to the same path
under `/usr`, and `exports.toml` adds the rest.

## What you do once

1. Create the public repo that holds the releases:

   ```
   gh repo create PoHsuanLai/desktop-releases --public \
     --description "Signed binary releases of the quire desktop (binaries only)" --add-readme
   ```

2. Make the signing key. Keep the secret key out of every repo (a password manager, or an offline file
   with mode 0600) and protect it with a password:

   ```
   mkdir -p ~/.config/quire-release && chmod 700 ~/.config/quire-release
   minisign -G -p ~/.config/quire-release/release.pub -s ~/.config/quire-release/release.key
   ```

3. Commit the public key to this repo. It is what `verify.sh` checks the CI's output against, and the file
   slipway reads on a machine is `/usr/share/slipway/release.pub` (the same file):

   ```
   cp ~/.config/quire-release/release.pub release/release.pub
   git add release/release.pub && git commit -m "release: the public signing key"
   ```

4. Make two fine-grained personal access tokens (GitHub, Settings, Developer settings):

   - `RELEASE_READ_TOKEN`: resource owner PoHsuanLai, repositories: every private repo in `manifest.toml`
     plus slipway (quire, sill, shell-host, blitz-kit, keycap, palmrest, porter, stoker, almanac, docket,
     cua, latchkey, bulkhead, bayonet, mailo, detent, anyview, mpv-wgpu, casement-protocols, casement,
     slipway); permission Contents: Read-only, and nothing else.
   - `RELEASES_TOKEN`: repository PoHsuanLai/desktop-releases only; permission Contents: Read and write.

5. Store the three secrets and the password (the pasted key is the whole file):

   ```
   gh secret set RELEASE_READ_TOKEN   --repo PoHsuanLai/desktop
   gh secret set RELEASES_TOKEN       --repo PoHsuanLai/desktop
   gh secret set MINISIGN_SECRET_KEY  --repo PoHsuanLai/desktop < ~/.config/quire-release/release.key
   gh secret set MINISIGN_PASSWORD    --repo PoHsuanLai/desktop
   ```

## Cutting a release

Pin the revs you want in `manifest.toml` (slipway included), push, then either:

```
gh workflow run release.yml --repo PoHsuanLai/desktop -f version=0.2.0 -f notes="What changed, in plain words."
```

or tag: `git tag -a v0.2.0 -m "What changed" && git push origin v0.2.0` (the tag's message is the notes).
The workflow builds the components in parallel jobs (casement, sill, anyview, mailo, porter, and the small
ones together), packs and signs, verifies, and creates the release `v0.2.0` in desktop-releases. Watch it with
`gh run watch --repo PoHsuanLai/desktop`. A tag that already exists in desktop-releases fails the last step;
nothing is overwritten.

## First install on a machine

slipway installs the desktop, so slipway's own pieces come first: its `scripts/install.sh` puts the privileged
helper at `/usr/libexec/slipway-apply`, its polkit action, the user unit and the release key at
`/usr/share/slipway/release.pub`. Then `release/bootstrap.sh` fetches the latest release from
desktop-releases, checks it with `verify.sh` against that key, and runs `pkexec /usr/libexec/slipway-apply`
on it:

```
cd slipway && sudo scripts/install.sh --pubkey /path/to/release.pub
cd ../desktop && release/bootstrap.sh
```

The helper is not part of any release (a release must not replace a binary that runs as root); later
releases arrive through slipway's daily check. `release/bootstrap.sh --verify-only` downloads and checks
without installing.

## Local trial

`release/selftest.sh` needs only python3, zstd and minisign. A real local build is
`release/build.sh --version 0.0.0-dev --out /tmp/rel` (siblings beside this repo, at the manifest revs, or
`RELEASE_ALLOW_DIRTY_REVS=1`), then `release/pack.sh --stage /tmp/rel/stage --version 0.0.0-dev --notes notes.txt
--out /tmp/rel/out --components /tmp/rel/components.txt` (`cat /tmp/rel/components.d/*.txt >components.txt`) with
`MINISIGN_KEY_FILE` set, and `release/verify.sh /tmp/rel/out --pubkey release/release.pub`.

## Limits worth knowing

- GitHub-hosted runners have about 14 GB of free disk and a 6 hour job limit; casement and sill are the
  heavy builds and each has its own job and its own cache. The repo cache limit is 10 GB: if the cache
  evicts, builds get slower, not wrong.
- The signing needs minisign 0.11 or later (it signs prehashed by default; `pack.sh` also passes `-H`, and
  `verify.sh` refuses a legacy signature, which is what slipway does).
- slipway's limits are checked by `pack.sh` and `verify.sh`: bundle 1 byte to 8 GiB, at most 100000 files, files
  totalling at most 16 GiB, notes at most 16 KiB, `release.toml` at most 24 MiB; `.slipway/` is a reserved
  path; modes must be readable by the owner and not writable by group or others; exports point at files.
- The signature covers `release.toml`; the digests in it cover the bundle and every file.
