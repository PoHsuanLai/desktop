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
system = []           # destinations listed as [[system]]
listed_sha = {}
size_delta = 0
version, date, notes, legacy = "9.9.9", "2026-01-01T00:00:00Z", "forged", False

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
elif case == "export-polkit":
    exports.append(("/usr/share/polkit-1/actions/org.example.root-for-all.policy", "bin/tool"))
elif case == "export-target":
    exports.append(("/usr/local/bin/ghost", "bin/ghost"))
elif case == "export-dir":
    exports.append(("/usr/local/bin/dir", "share"))
elif case == "system-good":
    files["system/etc/pam.d/sill"] = (b"auth required pam_unix.so\n", 0o644)
    system.append("/etc/pam.d/sill")
elif case == "system-xdg-other":
    files["system/etc/xdg/other.toml"] = (b"x = 1\n", 0o644)
    system.append("/etc/xdg/other.toml")
elif case == "system-dir":
    files["system/etc/passwd"] = (b"root::0:0:::\n", 0o644)
    system.append("/etc/passwd")
elif case == "system-unnamed":
    files["system/etc/polkit-1/rules.d/00-all.rules"] = (b"polkit.addRule(function () { return polkit.Result.YES; });\n", 0o644)
    system.append("/etc/polkit-1/rules.d/00-all.rules")
elif case == "system-nested":
    files["system/etc/pam.d/sub/sill"] = (b"x\n", 0o644)
    system.append("/etc/pam.d/sub/sill")
elif case == "system-unlisted":
    files["system/etc/pam.d/sill"] = (b"x\n", 0o644)
elif case == "system-nosource":
    system.append("/etc/pam.d/sill")
elif case == "reserved":
    files[".slipway/release.toml"] = (b"x", 0o644)
elif case == "mode-writable":
    files["bin/tool"] = (GOOD["bin/tool"][0], 0o775)
elif case == "mode-unreadable":
    files["bin/tool"] = (GOOD["bin/tool"][0], 0o311)
elif case == "version-zero":
    version = "01.2.3"
elif case == "version-pre":
    version = "1.0.0-01"
elif case == "date":
    date = "2026-13-45T25:61:61Z"
elif case == "notes-big":
    notes = "x" * (16 * 1024 + 1)
elif case == "notes-del":
    notes = "a\x7fb"
elif case == "legacy":
    legacy = True
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
lines = ['format = 1', f'version = "{version}"', f'date = "{date}"', f'notes = "{notes}"',
         f'bundle = {{ name = "bundle.tar.zst", sha256 = "{hashlib.sha256(bundle).hexdigest()}", size = {len(bundle) + size_delta} }}',
         "", "[components]", 'casement = "abc"']
for name, (data, mode) in sorted(files.items()):
    lines += ["", "[[file]]", f'path = "{name}"', f'sha256 = "{listed_sha.get(name, hashlib.sha256(data).hexdigest())}"', f"mode = 0o{mode:o}"]
for link, target in exports:
    lines += ["", "[[export]]", f'link = "{link}"', f'target = "{target}"']
for dest in system:
    lines += ["", "[[system]]", f'path = "{dest}"']
path = os.path.join(out, "release.toml")
open(path, "w").write("\n".join(lines) + "\n")
subprocess.run(["minisign", "-S", "-l" if legacy else "-H", "-s", key, "-m", path, "-x", path + ".minisig"], input=b"\n", check=True, capture_output=True)
if case == "tamper":   # signed, then changed
    open(path, "a").write("# changed after signing\n")
