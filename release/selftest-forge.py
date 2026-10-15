"""Forges hostile releases for selftest.sh: a release that is signed (with the throwaway key) and
internally consistent except for one thing verify.sh must refuse. Run: python3 -I selftest-forge.py OUT CASE KEY."""
import hashlib
import io
import os
import subprocess
import sys
import tarfile

out, case, key = sys.argv[1:4]
GOOD = {"bin/tool": (b"#!/bin/sh\necho hi\n", 0o755), "share/quire/data.txt": (b"data\n", 0o644)}
files = dict(GOOD)
members = []          # extra raw tar members: (name, kind, data)
exports = [("/usr/local/bin/tool", "bin/tool")]
listed_sha = {}
size_delta = 0

if case == "extra":
    members.append(("share/quire/unlisted.txt", "file", b"surprise\n"))
elif case == "digest":
    listed_sha["bin/tool"] = "0" * 64
elif case == "symlink":
    members.append(("bin/link", "symlink", b"tool"))
elif case == "dotdot":
    files["../evil"] = (b"x", 0o644)
elif case == "absolute":
    files["/etc/evil"] = (b"x", 0o644)
elif case == "export":
    exports.append(("/etc/cron.d/evil", "bin/tool"))
elif case == "export-target":
    exports.append(("/usr/local/bin/ghost", "bin/ghost"))
elif case == "size":
    size_delta = 1
elif case == "setuid":
    files["bin/tool"] = (GOOD["bin/tool"][0], 0o4755)
elif case not in ("tamper", "good"):
    sys.exit(f"unknown case {case}")

os.makedirs(out, exist_ok=True)
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
    for name, (data, mode) in sorted(files.items()):
        info = tarfile.TarInfo(name)
        info.size, info.mode = len(data), mode
        tar.addfile(info, io.BytesIO(data))
    for name, kind, data in members:
        info = tarfile.TarInfo(name)
        if kind == "symlink":
            info.type, info.linkname = tarfile.SYMTYPE, data.decode()
            tar.addfile(info)
        else:
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
raw = os.path.join(out, "bundle.tar")
open(raw, "wb").write(buf.getvalue())
subprocess.run(["zstd", "-q", "-f", "--no-progress", raw, "-o", os.path.join(out, "bundle.tar.zst")], check=True)
os.remove(raw)
bundle = open(os.path.join(out, "bundle.tar.zst"), "rb").read()
lines = ['format = 1', 'version = "9.9.9"', 'date = "2026-01-01T00:00:00Z"', 'notes = "forged"',
         f'bundle = {{ name = "bundle.tar.zst", sha256 = "{hashlib.sha256(bundle).hexdigest()}", size = {len(bundle) + size_delta} }}',
         "", "[components]", 'casement = "abc"']
for name, (data, mode) in sorted(files.items()):
    lines += ["", "[[file]]", f'path = "{name}"', f'sha256 = "{listed_sha.get(name, hashlib.sha256(data).hexdigest())}"', f"mode = 0o{mode:o}"]
for link, target in exports:
    lines += ["", "[[export]]", f'link = "{link}"', f'target = "{target}"']
path = os.path.join(out, "release.toml")
open(path, "w").write("\n".join(lines) + "\n")
subprocess.run(["minisign", "-S", "-s", key, "-m", path, "-x", path + ".minisig"], input=b"\n", check=True, capture_output=True)
if case == "tamper":   # signed, then changed
    open(path, "a").write("# changed after signing\n")
