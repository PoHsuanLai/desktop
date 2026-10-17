"""Which build job may supply which path of a release (re-audit NEW-ROOT-2). Run with `python3 -I`; standard library only.

  stage-owners.py check MANIFEST DIR...   each DIR is one downloaded artifact, named stage-JOB, and the job is the folder's
                                          name, never a name inside it. Refuse (exit 1) when a folder holds anything but
                                          exactly its own stage-JOB.tar (a plain file), when a tar holds a member outside
                                          its job's lines in MANIFEST, a member that is not a plain file or folder, or a
                                          path that two tars both hold. Prints every fault, then exits.
  stage-owners.py jobs MANIFEST           the job names MANIFEST knows, one per line (release/selftest.sh compares them with
                                          the matrix of .github/workflows/release.yml)

The workflow downloads each artifact into its own folder (no merging), so a build job cannot pass its tar off as another
job's by what it names a file.

The tar is what `tar -C build/release -cf stage-JOB.tar stage components.d` makes: members are stage/opt/quire/current/PATH
and components.d/NAME.txt. A MANIFEST pattern is PATH below opt/quire/current (or components.d/NAME.txt); `*` is any run of
characters inside one segment, `**` anything.
"""
import os
import re
import stat
import sys
import tarfile

CURRENT = "stage/opt/quire/current"
# Folders a tar may hold besides the ones inside CURRENT: the two it is made from and the ones on the way to CURRENT.
BARE_DIRS = {"stage", "stage/opt", "stage/opt/quire", "components.d"}


def glob_regex(pattern):
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def read_manifest(path):
    """{job: [compiled pattern, ...]}; a malformed line stops everything."""
    jobs = {}
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 2:
                raise SystemExit(f"{path}:{number}: expected JOB PATTERN, got {line!r}")
            job, pattern = parts
            if pattern.startswith("/") or ".." in pattern.split("/"):
                raise SystemExit(f"{path}:{number}: the pattern must be a clean relative path: {pattern!r}")
            jobs.setdefault(job, []).append(glob_regex(pattern))
    if not jobs:
        raise SystemExit(f"{path}: no lines")
    return jobs


def key_of(name):
    """The manifest key of a member name (None when it is outside both places a tar may write)."""
    if name.startswith("components.d/"):
        return name
    if name.startswith(CURRENT + "/"):
        return name[len(CURRENT) + 1:]
    return None


def own_tar(folder, job):
    """(path, None) of the one tar a folder may hold, or (None, why) when it holds anything else."""
    try:
        entries = sorted(os.listdir(folder))
    except OSError as e:
        return None, f"cannot be read ({e.strerror})"
    want = f"stage-{job}.tar"
    if entries != [want]:
        return None, f"must hold exactly {want}, holds {entries or 'nothing'}"
    path = os.path.join(folder, want)
    if not stat.S_ISREG(os.lstat(path).st_mode):
        return None, f"{want} is not a plain file"
    return path, None


def check(manifest, folders):
    jobs = read_manifest(manifest)
    faults, seen = [], {}
    for folder in folders:
        base = os.path.basename(os.path.normpath(folder))
        match = re.fullmatch(r"stage-([A-Za-z0-9_]+)", base)
        if not match or match.group(1) not in jobs:
            faults.append(f"{base}: not the artifact of a job {manifest} knows ({', '.join(sorted(jobs))})")
            continue
        job = match.group(1)
        tar_path, why = own_tar(folder, job)
        if tar_path is None:
            faults.append(f"{base}: {why}")
            continue
        names = set()
        with tarfile.open(tar_path) as tar:
            for member in tar:
                name = member.name[2:] if member.name.startswith("./") else member.name
                name = name.rstrip("/") if member.isdir() else name
                where = f"{job}: {name}"
                if name.startswith("/") or ".." in name.split("/") or "\\" in name:
                    faults.append(f"{where}: not a clean relative path")
                    continue
                if name in names:
                    faults.append(f"{where}: twice in one tar")
                names.add(name)
                if member.isdir():
                    if name not in BARE_DIRS and not (name + "/").startswith(CURRENT + "/"):
                        faults.append(f"{where}: a folder outside {CURRENT}")
                    continue
                if not member.isreg():
                    faults.append(f"{where}: neither a plain file nor a folder")
                    continue
                key = key_of(name)
                if key is None:
                    faults.append(f"{where}: outside {CURRENT} and components.d")
                elif not any(p.match(key) for p in jobs[job]):
                    faults.append(f"{where}: not a path job {job} may supply ({key})")
                elif key in seen:
                    faults.append(f"{where}: also supplied by job {seen[key]}")
                else:
                    seen[key] = job
    for fault in faults:
        print(f"stage-owners: {fault}", file=sys.stderr)
    return 1 if faults else 0


def main(argv):
    if len(argv) >= 4 and argv[1] == "check":
        return check(argv[2], argv[3:])
    if len(argv) == 3 and argv[1] == "jobs":
        print("\n".join(sorted(read_manifest(argv[2]))))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
