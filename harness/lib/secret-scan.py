#!/usr/bin/env python3
"""The accounts scenarios' secret scan: fails when a planted secret (a password, a refresh token, an API key,
an access token the rig planted or the issuer minted) shows up where it must not.

  secret-scan.py --bus bus.jsonl --secret S... --pattern RE... --file F... [--dir D...] [--report out.txt]

--bus   a `busctl monitor --json=short` record of the private bus (every message, both directions).
--secret / --pattern   exact strings (rig.json "secrets") and regular expressions (the issuer's minted tokens,
        `fake-refresh-[0-9]+`).
--file / --dir   logs and state files to grep (bytes), a directory recursively.

What a bus message may carry (the design lets exactly these through; every other hit fails the scan):
  - the Secret Service: calls to org.freedesktop.secrets and their replies (accountd files and reads its
    credentials there, by design: the store is the one place they live);
  - AccountsSheet1.Input, the unicast signal from the sheet host to accountd with the answers a person typed
    (a password goes from the sheet to accountd once, by design);
  - org.quire.Casement.Debug1.Inject and its reply: the test typing the person's keys;
  - an ACCESS token (planted or minted) in the reply to Tokens.IssueToken: apps receive short-lived tokens.
A refresh token, a password or an API key in any other message, or any secret in a log or a state file, is a hit.

Reports what it saw: messages scanned, exempt hits by reason, and hits.  Exit 0 clean, 1 hits, 2 bad input.
Run with -I."""
import argparse
import json
import os
import re
import sys


def flat(value, out):
    """Every string and every byte array (a list of ints 0..255) of a payload, as text."""
    if isinstance(value, dict):
        for item in value.values():
            flat(item, out)
    elif isinstance(value, list):
        if value and all(isinstance(i, int) and 0 <= i < 256 for i in value):
            out.append(bytes(value).decode("latin1"))
        else:
            for item in value:
                flat(item, out)
    elif isinstance(value, str):
        out.append(value)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bus")
    ap.add_argument("--secret", action="append", default=[])
    ap.add_argument("--pattern", action="append", default=[])
    ap.add_argument("--access-pattern", action="append", default=[],
                    help="access tokens: allowed in the reply to IssueToken only")
    ap.add_argument("--access-secret", action="append", default=[])
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--dir", action="append", default=[])
    ap.add_argument("--report")
    a = ap.parse_args()

    secrets = [s.encode("latin1") for s in a.secret]
    patterns = [re.compile(p.encode()) for p in a.pattern]
    access = [re.compile(re.escape(s).encode()) for s in a.access_secret] + [re.compile(p.encode()) for p in a.access_pattern]
    lines = []
    hits = 0
    exempt = {}

    def which(text, with_access):
        raw = text.encode("latin1", "replace")
        for s in secrets:
            if s in raw:
                return s.decode("latin1")
        for p in patterns + (access if with_access else []):
            m = p.search(raw)
            if m:
                return m.group(0).decode("latin1")
        return None

    if a.bus:
        try:
            msgs = [json.loads(l) for l in open(a.bus) if l.strip()]
        except (OSError, ValueError) as e:
            print("secret-scan: cannot read the bus record: %s" % e, file=sys.stderr)
            return 2
        secrets_unique = set()   # unique names that own org.freedesktop.secrets
        for m in msgs:
            if m.get("member") == "NameOwnerChanged":
                d = m["payload"]["data"]
                if d[0] == "org.freedesktop.secrets" and d[2]:
                    secrets_unique.add(d[2])
        # reply cookies of calls to the Secret Service and to IssueToken
        to_secrets, to_issue, to_inject = set(), set(), set()
        for m in msgs:
            if m["type"] == "method_call":
                dest, member = m.get("destination", ""), m.get("member", "")
                key = (m.get("sender"), m.get("cookie"))
                if dest == "org.freedesktop.secrets" or dest in secrets_unique or str(m.get("interface", "")).startswith("org.freedesktop.Secret"):
                    to_secrets.add(key)
                if member == "IssueToken":
                    to_issue.add(key)
                if m.get("interface") == "org.quire.Casement.Debug1":
                    to_inject.add(key)
        for m in msgs:
            out = []
            flat(m.get("payload"), out)
            text = "\n".join(out)
            is_issue_reply = m["type"] == "method_return" and (m.get("destination"), m.get("reply_cookie")) in to_issue
            hit = which(text, with_access=not is_issue_reply)
            if hit is None:
                continue
            sender, dest = m.get("sender", ""), m.get("destination", "")
            why = None
            if m["type"] == "method_call" and (dest == "org.freedesktop.secrets" or dest in secrets_unique):
                why = "the Secret Service call"
            elif m["type"] == "method_return" and (dest, m.get("reply_cookie")) in to_secrets:
                why = "the Secret Service reply"
            elif m["type"] == "signal" and m.get("interface") == "org.quire.AccountsSheet1" and m.get("member") == "Input":
                why = "the sheet host's Input to accountd"
            elif m.get("interface") == "org.quire.Casement.Debug1" or (m["type"] == "method_return" and (dest, m.get("reply_cookie")) in to_inject):
                why = "the test typing (casement Inject)"
            elif is_issue_reply:
                why = "the access token in IssueToken's reply"
            if why:
                exempt[why] = exempt.get(why, 0) + 1
                continue
            hits += 1
            lines.append("HIT bus %s %s -> %s %s.%s carries %s" % (m["type"], sender, dest, m.get("interface"), m.get("member"), hit[:60]))
        lines.append("bus: %d messages scanned" % len(msgs))
    for why, n in sorted(exempt.items()):
        lines.append("exempt (by design): %d x %s" % (n, why))

    paths = list(a.file)
    for d in a.dir:
        for root, _dirs, files in os.walk(d):
            for f in files:
                paths.append(os.path.join(root, f))
    scanned = 0
    for p in paths:
        try:
            raw = open(p, "rb").read()
        except OSError:
            continue
        scanned += 1
        for s in secrets:
            if s in raw:
                hits += 1
                lines.append("HIT file %s holds %s" % (p, s.decode("latin1")))
        for pat in patterns + access:
            m = pat.search(raw)
            if m:
                hits += 1
                lines.append("HIT file %s holds %s" % (p, m.group(0).decode("latin1")[:60]))
    lines.append("files: %d scanned" % scanned)
    text = "\n".join(lines)
    if a.report:
        open(a.report, "w").write(text + "\n")
    print(text)
    return 1 if hits else 0


sys.exit(main())
