"""What slipway's install must have put on a computer before a release can be installed or gone back from:
three privileged programs and the one policy file that names them. Run with `python3 -I` through
release/check-helpers.sh. Standard library only.

The decisions it holds the files to (owner, 2026-10-16): installing a signed newer release and noting a good start
need no password for the person at the keyboard; going back to an earlier version asks for the administrator's
password; nobody who is not at the keyboard is allowed any of it.
"""
import os
import stat as S
import sys
import xml.etree.ElementTree as ET

PROGRAMS = ("slipway-apply", "slipway-rollback", "slipway-health")
# action id -> (program, what an active session at the keyboard gets)
ACTIONS = {
    "org.quire.slipway.apply": ("slipway-apply", "yes"),
    "org.quire.slipway.rollback": ("slipway-rollback", "auth_admin_keep"),
    "org.quire.slipway.health": ("slipway-health", "yes"),
}
EXEC_PATH = "org.freedesktop.policykit.exec.path"


def problems(libexec, policy, root):
    found = []
    under = lambda path: os.path.join(root, path.lstrip("/"))
    for name in PROGRAMS:
        path = under(os.path.join(libexec, name))
        try:
            st = os.lstat(path)
        except OSError:
            found.append(f"{os.path.join(libexec, name)} is not installed")
            continue
        if not S.S_ISREG(st.st_mode) or not st.st_mode & S.S_IXUSR:
            found.append(f"{os.path.join(libexec, name)} is not a program")
        elif st.st_mode & (S.S_IWGRP | S.S_IWOTH):
            found.append(f"{os.path.join(libexec, name)} can be changed by someone other than its owner")
        elif os.geteuid() == 0 and st.st_uid != 0:
            found.append(f"{os.path.join(libexec, name)} is not owned by root")
    try:
        actions = ET.parse(under(policy)).getroot().findall("action")
    except (OSError, ET.ParseError) as e:
        return found + [f"{policy}: {e}"]
    by_id = {a.get("id"): a for a in actions}
    if sorted(by_id) != sorted(ACTIONS) or len(actions) != len(ACTIONS):
        found.append(f"{policy} holds the actions {sorted(a.get('id') or '?' for a in actions)}, not {sorted(ACTIONS)}")
    for action_id, (program, active) in ACTIONS.items():
        action = by_id.get(action_id)
        if action is None:
            continue
        want = os.path.join(libexec, program)
        paths = [n.text for n in action.findall("annotate") if n.get("key") == EXEC_PATH]
        if paths != [want]:
            found.append(f"{action_id} names {paths}, not {want}")
        defaults = action.find("defaults")
        got = {k: (defaults.findtext(k) or "").strip() if defaults is not None else "" for k in ("allow_any", "allow_inactive", "allow_active")}
        if got != {"allow_any": "no", "allow_inactive": "no", "allow_active": active}:
            found.append(f"{action_id} has the defaults {got}; wanted no, no and {active}")
    return found


def main(argv):
    libexec, policy, root = "/usr/libexec", "/usr/share/polkit-1/actions/org.quire.slipway.policy", "/"
    args = iter(argv)
    for arg in args:
        if arg == "--libexec":
            libexec = next(args)
        elif arg == "--policy":
            policy = next(args)
        elif arg == "--root":
            root = next(args)
        else:
            print(f"check-helpers: unknown argument {arg}", file=sys.stderr)
            return 2
    found = problems(libexec, policy, root)
    for line in found:
        print(f"check-helpers: {line}", file=sys.stderr)
    if not found:
        print(f"update programs in place: {', '.join(PROGRAMS)} in {libexec}, and {os.path.basename(policy)} with its {len(ACTIONS)} actions")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
