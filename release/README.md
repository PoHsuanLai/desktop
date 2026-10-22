# Releases

A signed binary bundle of the whole desktop, built by GitHub Actions at the revs `manifest.toml` pins and
published to the public repo `PoHsuanLai/desktop-releases` (binaries only; the source repos stay private).
slipway, the updater, reads it.

| File | What |
|---|---|
| `build.sh` | builds each component (`cargo build --release --locked`, run from `/` with `--manifest-path` so the system linker is used; see `install/cargo.sh`) and installs it under `/opt/quire/current` into a staging root |
| `pack.sh` | stage -> `release.toml` (digests, modes, components, exports), `bundle.tar.zst` (deterministic), `release.toml.minisig` |
| `verify.sh` | checks a packed release the way slipway will; the CI runs it before publishing |
| `system-files.list` | the system files a release may place, one rule each (a committed copy of slipway's `ALLOWED_SYSTEM_FILES`); `release.py` reads it, so `pack` and `verify` refuse a `system/` path no rule names |
| `check-system-list.sh` | fails unless that list equals slipway's own (the workflow runs it against the pinned slipway checkout) |
| `check-helpers.sh` | fails unless slipway's own install is complete: `slipway-apply`, `slipway-rollback` and `slipway-health` in `/usr/libexec`, and the one polkit file with its three actions (installing and the good-start note need no password at the keyboard, going back asks for the administrator's); `smoke.sh` and `bootstrap.sh` run it |
| `health-scenarios.sh` | two scenarios with slipway's real programs on a throwaway computer: two logins that run `recover` and `confirm` keep the newest release, and restarts that never confirm put the previous release back on the third; the workflow's `health` job runs it in a privileged container, and publishing waits for it |
| `selftest.sh` | packs a fake stage with a throwaway key, verifies it, and checks that hostile releases are refused; a SKIP (exit 2) without minisign; run by `gate/desktop-gate.sh --self` |
| `check-glibc.sh` | fails if a program in the stage needs a newer glibc (default 2.39), libstdc++ (GCC 13) or libgcc ABI than Ubuntu 24.04 has; the workflow runs it after each build |
| `check-ldd.sh` | fails if `ldd` reports a library "not found" for any program in a tree; run after the build and again inside each distribution |
| `deps.sh` | the packages the flow needs per family (debian, fedora, arch): `tools`, `build`, `runtime` |
| `install-rustup.sh` | rustup from its published program for one version, SHA-256 checked (replaces `curl https://sh.rustup.rs | sh` in the workflow) |
| `install-zig.sh` | Zig 0.16 from the official tarball, SHA-256 checked (temor builds with it; no distribution ships a fixed 0.16) |
| `smoke.sh` | installs a packed release with slipway's helper on a throwaway machine (a CI container) and checks the links, system files, libraries and a repeat install |
| `lib.sh` | sourced by the scripts: the distribution family and the one-line install hint for a missing tool |
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
`/usr/lib/systemd/user`, `/usr/share/applications`, `/usr/share/quire`,
`/usr/share/porter`, `/usr/share/stoker`, `/usr/share/fonts` and `/usr/local/bin`; every file staged under
the first nine directories (as `share/...` or `lib/systemd/user`) is exported to the same path under `/usr`,
and `exports.toml` adds the rest. There is no polkit actions folder in the list: an action can make `pkexec` run a program as root with no
password, so no release can add one (slipway's own comes from its `scripts/install.sh`).

`[[system]]` (`path`): a file slipway's helper copies, as root, to an absolute path on the computer. Its
contents are the bundle file `system/<path>` (so `system/etc/pam.d/sill` lands at `/etc/pam.d/sill`); every
file under `system/` must be listed and every listed path needs its file. The path must be named by a rule of
`system-files.list`, which is slipway's `ALLOWED_SYSTEM_FILES` word for word: twenty-one rules, each a folder and either an
exact file name or a name ending (`/etc/quire/*-callers.toml`, `/etc/xdg/quire/*.toml`). A path no rule names
refuses the whole release, at `pack`, at `verify` and in the helper. Because the helper is installed by hand and is
never replaced by a release, adding a system file means changing slipway's list, installing the new helper on every
computer, and changing `system-files.list` in the same step (`check-system-list.sh` fails the build if the two differ).
`build.sh` stages keycap's unit and polkit rule (no device rule and no module list of its own: the input service owns `/dev/uinput`),
the input service's `turnstile.socket`, `turnstile.service`, `72-turnstile.rules` (the node becomes root-only and loses the `uaccess` tag)
and `turnstile.conf` (loads `uinput`), with its `/usr/local/bin/turnstile` export (`exports.toml`), the table of the desktop's own programs
`/etc/quire/desktop-callers.toml` (from `dist/`; the update service, the screen-sharing service and the input service refuse every caller
without it),
palmrest's unit (a system service since 2026-10-17, like keycap), its udev rule (the mouse's raw node to the `input` group, no person) and module options, sill's PAM service and its external-monitor brightness files (the udev rule
`60-sill-ddc.rules` and the `i2c-dev` module list) porter's, almanac's, docket's and cua's caller tables (`/etc/quire`) and docket's default settings (`/etc/xdg/quire`) there. The session component also
stages the colour emoji font at `share/fonts/quire/Noto-COLRv1.ttf` (with its licence), which is exported to
`/usr/share/fonts/quire/`, a folder quire's emoji search reads.

A unit that a row of `dist/desktop-callers.toml` names (the shell, the compositor, the portal backend, the accounts, intent, companion and memory services, Settings, the
computer-use daemon) must be a **plain root-owned file**, not a link: a staged `lib/systemd/user/X.service` is exported as a link under `/usr/lib/systemd/user`, and the
unit manager's judge reads a link (mode 0777) as a fragment anyone could change, so the unit never proves `Full` and its callers are refused. `build.sh`'s `plain_units`
therefore stages those units, with the `sandbox.conf` drop-ins appended to their text, as system files at `/usr/lib/systemd/user/X.service` (the rule `/usr/lib/systemd/user
ending .service` of the list), and the portal frontend's drop-in at `/usr/lib/systemd/user/xdg-desktop-portal.service.d/10-quire.conf`; the build stops if a named unit is
still staged where it would be exported. Units that no row names (`mailo-watch.service`, the session target) stay exported links. The system units of turnstile, keycap
and palmrest are system files in `/usr/lib/systemd/system` and were never links.

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

3. Commit the public key to this repo, **before the first run**: the pack job stops at once without it. It is what
   `verify.sh` checks the CI's output against, and the file slipway reads on a machine is
   `/usr/share/slipway/release.pub` (the same file). Its first line carries the key id; the workflow prints it in every
   run, and `sed -n 1p release/release.pub` shows it, so a person can compare the two:

   ```
   cp ~/.config/quire-release/release.pub release/release.pub
   git add release/release.pub && git commit -m "release: the public signing key"
   sed -n 1p release/release.pub
   ```

4. Make two fine-grained personal access tokens (GitHub, Settings, Developer settings):

   - `RELEASE_READ_TOKEN`: resource owner PoHsuanLai, repositories: every private repo in `manifest.toml`
     plus slipway (quire, sill, shell-host, blitz-kit, keycap, palmrest, porter, stoker, almanac, docket,
     cua, latchkey, bulkhead, bayonet, mailo, files, detent, transom, anyview, mpv-wgpu, casement-protocols, casement,
     slipway); permission Contents: Read-only, and nothing else.
   - `RELEASES_TOKEN`: repository PoHsuanLai/desktop-releases only; permission Contents: Read and write.

5. Make the two environments the workflow's signing and publishing jobs run in, each usable only from the default
   branch and from `v*` tags, each with you as the required reviewer (you approve each run on GitHub; a run from any other
   branch is refused before it can read a secret). The workflow's `environment:` lines are what bind the jobs to them:

   ```
   for env in release-signing release-publish; do
     gh api -X PUT repos/PoHsuanLai/desktop/environments/$env \
       -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true' \
       -F 'reviewers[][type]=User' -F "reviewers[][id]=$(gh api user --jq .id)"
     gh api -X POST repos/PoHsuanLai/desktop/environments/$env/deployment-branch-policies -f name=master -f type=branch
     gh api -X POST repos/PoHsuanLai/desktop/environments/$env/deployment-branch-policies -f name='v*' -f type=tag
   done
   ```

   Also restrict who may create `v*` tags (Settings, Rules, Rulesets: a tag ruleset on `v*` that blocks creation and
   deletion for everyone but you), because a pushed tag is allowed to use the environments.

6. Store the secrets: the signing key and its password in `release-signing`, the release token in `release-publish`, and
   the read-only token as a repository secret (the pasted key is the whole file). Then **delete any repository-level copy
   of the signing key, its password and `RELEASES_TOKEN`**: a repository secret of the same name is readable by a workflow
   run from any branch, which is what the environments are there to prevent:

   ```
   gh secret set MINISIGN_SECRET_KEY --env release-signing --repo PoHsuanLai/desktop < ~/.config/quire-release/release.key
   gh secret set MINISIGN_PASSWORD   --env release-signing --repo PoHsuanLai/desktop
   gh secret set RELEASES_TOKEN      --env release-publish --repo PoHsuanLai/desktop
   gh secret set RELEASE_READ_TOKEN  --repo PoHsuanLai/desktop
   gh secret delete MINISIGN_SECRET_KEY --repo PoHsuanLai/desktop   # only if an earlier setup made it
   gh secret delete MINISIGN_PASSWORD   --repo PoHsuanLai/desktop   # only if an earlier setup made it
   gh secret delete RELEASES_TOKEN      --repo PoHsuanLai/desktop   # only if an earlier setup made it
   ```

What this does not do: there is one signing key, and slipway's privileged helper trusts exactly that key file, so
replacing a lost or stolen key means each person runs slipway's install with the new `--pubkey` again. A second signer
or a list of next keys would need a change to slipway's key handling and a new helper on every computer (owner's
decision, recorded in FINDINGS).

## Cutting a release

Pin the revs you want in `manifest.toml` (slipway included), push, then either:

```
gh workflow run release.yml --repo PoHsuanLai/desktop -f version=0.2.0 -f notes="What changed, in plain words."
```

or tag: `git tag -a v0.2.0 -m "What changed" && git push origin v0.2.0` (the tag's message is the notes).
The notes for the next release are kept in `docs/release-notes.md` while it is prepared; use them as the text.
The workflow builds the components in parallel jobs (casement, sill, anyview, mailo, files, porter, almanac with docket, stoker and cua, turnstile, keycap and palmrest (the programs the system manager starts, a job each), and the small ones together, with xwayland-satellite, which is built from its public repository at the commit in `build.sh`, `SATELLITE_REV`, the one `SATELLITE_TAG` names) in an `ubuntu:24.04` container (the oldest supported base, so the programs load on Fedora and
Arch as well), checks their glibc and library needs, packs and signs, verifies, installs the signed release with
slipway's helper in clean Ubuntu 24.04, Fedora 44 and Arch containers, and only then creates the release
`v0.2.0` in desktop-releases. Watch it with
`gh run watch --repo PoHsuanLai/desktop`. A tag that already exists in desktop-releases fails the last step;
nothing is overwritten.

Each build job may supply only the paths `release/stage-owners.list` gives it. Before the stage tars are merged, the pack job runs
`release/stage-owners.py check` on them and stops when a tar holds a path outside its job's lines (a build script in one job writing
`bin/turnstile` or `turnstile.service`, say), anything that is not a plain file or folder, or a path that two jobs both supply. A component
that starts to install a new file needs a line for it in that list. The job is taken from the artifact, not from a file name: the pack job
downloads each `stage-JOB` artifact into a folder of its own (no `merge-multiple`) and the check refuses a folder that holds anything but
exactly its own `stage-JOB.tar`, so an artifact `stage-x` holding a file `stage-turnstile.tar` is not turnstile's.

## First install on a machine

slipway installs the desktop, so slipway's own pieces come first. Its `scripts/install.sh` puts three privileged
programs in `/usr/libexec`, the one polkit file that names them, the user unit and bus file, the system settings and the
release key at `/usr/share/slipway/release.pub`:

| Program | What it does | Password |
|---|---|---|
| `slipway-apply` | installs a signed release that is newer than the one in use | none, for the person at the keyboard (it checks the signature itself) |
| `slipway-rollback` | goes back to the previous release | the administrator's, kept for a few minutes |
| `slipway-health` | keeps the record of which starts went well and puts the previous release back after several failed ones | none, and only root can write its record |

Then `release/bootstrap.sh` fetches the latest release from desktop-releases, checks it with `verify.sh` against that key,
checks slipway's install with `check-helpers.sh`, and runs `pkexec /usr/libexec/slipway-apply` on it:

```
cd slipway
cargo build --release --locked -p slipway-root
sudo sh -c 'umask 022 && scripts/install.sh --bin-dir target/release --pubkey /path/to/release.pub'
cd ../desktop && release/bootstrap.sh
```

The build runs as yourself, so no build step of the dependency tree runs as root, and the install gets the finished
programs with `--bin-dir`; without `--bin-dir` slipway's script builds them itself, as whoever runs it, which under `sudo`
means as root. The `umask 022` keeps `/etc/slipway` and `/usr/share/slipway` readable by your own session when root's umask is
stricter (the script writes with the umask it is run under, and the update service could not then read its settings or the
key). None of the three programs is part of any
release (a release must not replace a program that runs as root); later releases arrive through slipway's daily check, and a
change to a helper is a new run of slipway's install by hand. `release/bootstrap.sh --verify-only` downloads and checks
without installing. The way back by hand, from a text console, is `pkexec /usr/libexec/slipway-rollback`.

From then on the session does the rest: `desktop-session.target` wants the update service, `desktop-session` runs
`slipway recover` before the compositor starts, and the shell runs `slipway confirm` about half a minute after it
answers. CI covers the install on three distributions (`smoke.sh`) and the two start-check cases (`health-scenarios.sh`).

### Before the first release that carries the input service

Release N is the first to carry the four turnstile files. slipway's privileged helper is never replaced by a release, and an older one refuses
a release that lists a file its rule list does not name, so **everyone re-runs slipway's install by hand before that release** (the
`cd slipway && cargo build ... && sudo sh -c 'umask 022 && scripts/install.sh ...'` lines above, with a slipway that has the four rules and, in
`apply/settle.rs`, the step that reloads systemd and the device rules and starts `turnstile.socket`). A computer that skips it keeps working
at the version it has: the release is refused whole and says why. `release/system-files.list` and slipway's pin in `manifest.toml` move in
the same step; until then `release/check-system-list.sh` fails against the old pin, on purpose.

Carried by a release: `/usr/lib/keycap/keycap.toml` (Caps Lock switches the input method), keycap's vendor file. `/etc/keycap/keycap.toml` stays the
administrator's and no release or install writes it; keycap lays it over the vendor file. Slipway's list gained the rule after the first release that
carries the input service, so a computer whose helper is older than that rule must re-run slipway's install by hand before the release that lists it
(an older helper refuses that release whole). `./install.sh` places the same file (`install/system.sh keycap`, replacing it each time).

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
