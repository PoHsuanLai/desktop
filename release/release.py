"""The release bundle: pack a staged tree into release.toml + bundle.tar.zst (signed), and verify one
the way slipway does. Run with `python3 -I` through release/pack.sh and release/verify.sh; standard
library only (tomllib, tarfile, hashlib), plus the zstd and minisign programs.

Format 1: see release/README.md. The rules below are the whole contract:
  - the bundle holds regular files and directories only, relative clean paths, owner 0;
  - release.toml lists every regular file with its sha256 and mode, sorted by path;
  - exports are system links, each under one of EXPORT_ROOTS, each to a file in the bundle.
"""
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import stat as S
import tomllib

PREFIX = "opt/quire/current"
BUNDLE = "bundle.tar.zst"
SEMVER = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$")
DATE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
SHA = re.compile(r"^[0-9a-f]{64}$")
PART = re.compile(r"^[A-Za-z0-9._+@=,~-]+$")
EXPORT_ROOTS = (
    "/usr/share/wayland-sessions", "/usr/share/xdg-desktop-portal", "/usr/share/dbus-1/services",
    "/usr/lib/systemd/user", "/usr/share/applications", "/usr/share/polkit-1/actions", "/usr/local/bin",
)
# A staged directory that maps to the same path under /usr, with no listing needed.
AUTO_EXPORT_DIRS = (
    "share/wayland-sessions", "share/xdg-desktop-portal", "share/dbus-1/services", "lib/systemd/user",
    "share/applications", "share/polkit-1/actions",
)


class Refused(Exception):
    pass


def clean_path(path, what="path"):
    """A bundle path: relative, no empty, dot or dot-dot parts, plain characters only."""
    if not isinstance(path, str) or not path:
        raise Refused(f"{what}: empty")
    for part in path.split("/"):
        if part in ("", ".", "..") or not PART.match(part):
            raise Refused(f"{what} {path!r}: not a clean relative path")
    return path


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def export_ok(link):
    if not isinstance(link, str) or not link.startswith("/"):
        raise Refused(f"export link {link!r}: not absolute")
    parts = link[1:].split("/")
    if any(p in ("", ".", "..") or not PART.match(p) for p in parts):
        raise Refused(f"export link {link!r}: not a clean path")
    if not any(link.startswith(root + "/") for root in EXPORT_ROOTS):
        raise Refused(f"export link {link!r}: not under an allowed directory")


def toml_str(text):
    return json.dumps(text, ensure_ascii=False)


def ancestors(path):
    parts = path.split("/")[:-1]
    return ["/".join(parts[: i + 1]) for i in range(len(parts))]


# ---------------------------------------------------------------------------------------------- pack

def walk_stage(stage):
    """(files {rel: normalised mode}, dirs set) of the staged tree; refuses anything but files/dirs."""
    top = os.path.join(stage, *PREFIX.split("/"))
    if not os.path.isdir(top):
        raise Refused(f"no staged tree at {top}")
    for here, allowed in ((stage, "opt"), (os.path.join(stage, "opt"), "quire"), (os.path.join(stage, "opt", "quire"), "current")):
        extra = sorted(set(os.listdir(here)) - {allowed})
        if extra:
            raise Refused(f"{here}: files outside {PREFIX}: {', '.join(extra)}")
    files = {}
    for here, dirs, names in os.walk(top, followlinks=False):
        dirs.sort()
        for name in dirs + names:
            full = os.path.join(here, name)
            rel = os.path.relpath(full, top)
            clean_path(rel)
            st = os.lstat(full)
            if S.S_ISLNK(st.st_mode):
                raise Refused(f"{rel}: a symlink (the bundle holds none)")
            if S.S_ISREG(st.st_mode):
                files[rel] = 0o755 if st.st_mode & 0o111 else 0o644
            elif not S.S_ISDIR(st.st_mode):
                raise Refused(f"{rel}: neither a file nor a directory")
    if not files:
        raise Refused("the staged tree has no files")
    return files, {d for f in files for d in ancestors(f)}


def derive_exports(files, exports_file):
    out = {}
    for rel in files:
        if any(rel.startswith(d + "/") for d in AUTO_EXPORT_DIRS):
            out["/usr/" + rel] = rel
    if exports_file and os.path.exists(exports_file):
        with open(exports_file, "rb") as f:
            for e in tomllib.load(f).get("export", []):
                link, target = e.get("link"), e.get("target")
                if link in out:
                    raise Refused(f"export {link} given twice")
                out[link] = target
    for link, target in out.items():
        export_ok(link)
        if target not in files:
            raise Refused(f"export {link} points at {target!r}, which is not in the bundle")
    return dict(sorted(out.items()))


def read_components(manifest, extra):
    with open(manifest, "rb") as f:
        comps = {name: repo["rev"] for name, repo in tomllib.load(f).get("repo", {}).items()}
    if extra and os.path.exists(extra):
        for line in open(extra, encoding="utf-8"):
            if line.strip() and not line.startswith("#"):
                name, rev = line.split()
                comps[name] = rev
    return dict(sorted(comps.items()))


def make_bundle(stage, files, dirs, out):
    top = os.path.join(stage, *PREFIX.split("/"))
    raw = os.path.join(out, "bundle.tar")
    with tarfile.open(raw, "w", format=tarfile.GNU_FORMAT) as tar:
        for rel in sorted(dirs | set(files)):
            info = tarfile.TarInfo(rel)
            info.mtime, info.uid, info.gid, info.uname, info.gname = 0, 0, 0, "", ""
            if rel in files:
                info.size, info.mode = os.path.getsize(os.path.join(top, rel)), files[rel]
                with open(os.path.join(top, rel), "rb") as f:
                    tar.addfile(info, f)
            else:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                tar.addfile(info)
    subprocess.run(["zstd", "-19", "-T1", "-q", "-f", "--no-progress", raw, "-o", os.path.join(out, BUNDLE)], check=True)
    os.remove(raw)


def release_text(version, date, notes, bundle_path, comps, files, stage_top, exports):
    lines = ["format = 1", f"version = {toml_str(version)}", f"date = {toml_str(date)}", f"notes = {toml_str(notes)}",
             f'bundle = {{ name = "{BUNDLE}", sha256 = "{sha256_file(bundle_path)}", size = {os.path.getsize(bundle_path)} }}',
             "", "[components]"]
    lines += [f"{name} = {toml_str(rev)}" for name, rev in comps.items()]
    for rel, mode in sorted(files.items()):
        lines += ["", "[[file]]", f"path = {toml_str(rel)}", f'sha256 = "{sha256_file(os.path.join(stage_top, rel))}"', f"mode = 0o{mode:o}"]
    for link, target in exports.items():
        lines += ["", "[[export]]", f"link = {toml_str(link)}", f"target = {toml_str(target)}"]
    return "\n".join(lines) + "\n"


def sign(path):
    key = os.environ.get("MINISIGN_KEY_FILE")
    if not key:
        raise Refused("MINISIGN_KEY_FILE is not set")
    password = os.environ.get("MINISIGN_PASSWORD", "")
    subprocess.run(["minisign", "-S", "-s", key, "-m", path, "-x", path + ".minisig", "-t", "quire desktop release"],
                   input=(password + "\n").encode(), check=True)


def pack(a):
    if not SEMVER.match(a["version"]):
        raise Refused(f"version {a['version']!r} is not semver")
    files, dirs = walk_stage(a["stage"])
    top = os.path.join(a["stage"], *PREFIX.split("/"))
    exports = derive_exports(files, a["exports"])
    comps = read_components(a["manifest"], a["components"])
    notes = open(a["notes"], encoding="utf-8").read().strip()
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0")) or None
    now = datetime.datetime.fromtimestamp(epoch, datetime.UTC) if epoch else datetime.datetime.now(datetime.UTC)
    os.makedirs(a["out"], exist_ok=True)
    make_bundle(a["stage"], files, dirs, a["out"])
    text = release_text(a["version"], now.strftime("%Y-%m-%dT%H:%M:%SZ"), notes, os.path.join(a["out"], BUNDLE), comps, files, top, exports)
    path = os.path.join(a["out"], "release.toml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    sign(path)
    print(f"packed {a['version']}: {len(files)} files, {len(exports)} exports, bundle {os.path.getsize(os.path.join(a['out'], BUNDLE))} bytes")


# ------------------------------------------------------------------------------------------- verify

def check_signature(directory, pubkey):
    try:
        r = subprocess.run(["minisign", "-V", "-q", "-p", pubkey, "-m", os.path.join(directory, "release.toml"),
                            "-x", os.path.join(directory, "release.toml.minisig")], capture_output=True)
    except FileNotFoundError:
        raise Refused("minisign is not installed")
    if r.returncode != 0:
        raise Refused("release.toml: the signature does not verify")


def check_manifest(doc):
    if doc.get("format") != 1:
        raise Refused("format is not 1")
    if not SEMVER.match(str(doc.get("version", ""))):
        raise Refused("version is not semver")
    if not DATE.match(str(doc.get("date", ""))):
        raise Refused("date is not YYYY-MM-DDTHH:MM:SSZ")
    if not isinstance(doc.get("notes"), str):
        raise Refused("notes is not text")
    b = doc.get("bundle", {})
    if b.get("name") != BUNDLE or not SHA.match(str(b.get("sha256", ""))) or not isinstance(b.get("size"), int):
        raise Refused("bundle entry is malformed")
    comps = doc.get("components", {})
    if not isinstance(comps, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in comps.items()):
        raise Refused("components is malformed")
    files = {}
    paths = []
    for f in doc.get("file", []):
        path = clean_path(f.get("path"), "file path")
        if not SHA.match(str(f.get("sha256", ""))) or not isinstance(f.get("mode"), int) or f["mode"] & ~0o777:
            raise Refused(f"file {path}: bad digest or mode")
        if path in files:
            raise Refused(f"file {path} listed twice")
        files[path] = (f["sha256"], f["mode"])
        paths.append(path)
    if paths != sorted(paths):
        raise Refused("files are not sorted by path")
    if not files:
        raise Refused("no files")
    links = set()
    for e in doc.get("export", []):
        export_ok(e.get("link"))
        if e["link"] in links:
            raise Refused(f"export {e['link']} listed twice")
        links.add(e["link"])
        if clean_path(e.get("target"), "export target") not in files:
            raise Refused(f"export {e['link']}: target {e['target']} is not a bundle file")
    return b, files


def check_bundle(path, files):
    seen_files, seen_dirs = set(), set()
    p = subprocess.Popen(["zstd", "-dc", "-q", path], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=p.stdout, mode="r|") as tar:
            for m in tar:
                name = clean_path(m.name, "bundle member")
                if name in seen_files or name in seen_dirs:
                    raise Refused(f"bundle member {name} twice")
                if m.uid != 0 or m.gid != 0:
                    raise Refused(f"{name}: owner is not 0")
                if m.isdir():
                    seen_dirs.add(name)
                elif m.isreg():
                    if name not in files:
                        raise Refused(f"{name}: in the bundle but not listed")
                    digest, mode = files[name]
                    if (m.mode & 0o7777) != mode:
                        raise Refused(f"{name}: mode differs from release.toml")
                    h = hashlib.sha256()
                    src = tar.extractfile(m)
                    for block in iter(lambda: src.read(1 << 20), b""):
                        h.update(block)
                    if h.hexdigest() != digest:
                        raise Refused(f"{name}: digest differs from release.toml")
                    seen_files.add(name)
                else:
                    raise Refused(f"{name}: not a regular file or directory (links and devices are refused)")
    except tarfile.TarError as e:
        raise Refused(f"bundle is not a clean tar: {e}")
    finally:
        p.stdout.close()
        p.wait()
    if p.returncode != 0:
        raise Refused("bundle is not valid zstd")
    for missing in sorted(set(files) - seen_files):
        raise Refused(f"{missing}: listed but not in the bundle")
    wanted = {d for f in files for d in ancestors(f)}
    if seen_dirs - wanted:
        raise Refused(f"bundle holds directories nothing lives in: {sorted(seen_dirs - wanted)[0]}")
    return len(seen_files)


def verify(directory, pubkey):
    check_signature(directory, pubkey)
    with open(os.path.join(directory, "release.toml"), "rb") as f:
        doc = tomllib.load(f)
    bundle, files = check_manifest(doc)
    path = os.path.join(directory, BUNDLE)
    if os.path.islink(path) or not os.path.isfile(path):
        raise Refused("bundle.tar.zst is not a regular file")
    if os.path.getsize(path) != bundle["size"] or sha256_file(path) != bundle["sha256"]:
        raise Refused("bundle: size or digest differs from release.toml")
    n = check_bundle(path, files)
    print(f"verified {doc['version']}: {n} files, {len(doc.get('export', []))} exports")


def main(argv):
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "pack":
            keys = ("stage", "version", "notes", "out", "manifest", "exports", "components")
            pack(dict(zip(keys, rest + [""] * (len(keys) - len(rest)))))
        elif cmd == "verify":
            verify(rest[0], rest[1])
        else:
            raise Refused(f"unknown command {cmd}")
    except Refused as e:
        print(f"release: refused: {e}", file=sys.stderr)
        return 1
    except (subprocess.CalledProcessError, OSError, tomllib.TOMLDecodeError) as e:
        print(f"release: failed: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
