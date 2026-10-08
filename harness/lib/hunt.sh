# What the hunt-* probes share (on top of harness/lib/accounts.sh): observations recorded to a file the person reads
# after the run, a second brand file whose server is dead, and answers read back from the app that asked.
# Sourced after accounts.sh.

# obs TEXT: one observation line (printed, and kept in $OUT_DIR/obs.txt).
obs() { echo "OBS $*" | tee -a "$OUT_DIR/obs.txt" >&2; }

# bug TEXT: a finding that fails the step (the probe asserted what a person expects).
bug() { echo "BUG $*" | tee -a "$OUT_DIR/obs.txt" >&2; HUNT_BUGS=$(( ${HUNT_BUGS:-0} + 1 )); return 1; }

# acc_dead_mail_provider: a brand file like fake-mail whose servers refuse connections (nothing listens on 127.0.0.1:9).
acc_dead_mail_provider() {
  cat >"$PROV/dead-mail.toml" <<EOT
id = "dead-mail"
label = "Dead Mail"
mark = "mail"

[auth]
kind = "password"

[discovery]
kind = "fixed"

[[capability]]
family = "imap"
endpoint = "imaps://127.0.0.1:9"
kind = "mail"
v = { access = "read_write", send = "present", delta = "poll", transport = "imap", labels = "folders" }

[[capability]]
family = "smtp"
endpoint = "smtps://127.0.0.1:9"
kind = "mail"
v = { access = "read_write", send = "present", delta = "poll", transport = "imap", labels = "folders" }
EOT
}

# hunt_boot_mail: casement, recorded bus, the fakes, Secret Service, accountd, sill; fake-mail and dead-mail are listed.
hunt_boot_mail() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  [ -z "${HUNT_THEME:-}" ] || printf '[appearance]\ntheme = "%s"\n' "$HUNT_THEME" >"$CONFIG/quire/appearance.toml"
  scan_begin
  rig_start --imap --smtp --tls implicit || return 1
  secrets_start || return 1
  acc_config; acc_fake_mail_provider; acc_dead_mail_provider
  accountd_start || return 1
  sill_start || return 1
}

# add_answer [SECONDS]: the add-account line, or `none` after the wait.
add_answer() { acc_add_response "${1:-8}" || echo none; }

# accounts_now: the account ids in accountd's settings module, space separated.
accounts_now() {
  settings_describe | python3 -I -c '
import json, sys
ids = []
for k in json.load(sys.stdin)["key"]:
    p = k["path"]
    if p.startswith("accounts.") and p.endswith(".state"): ids.append(p[len("accounts."):-len(".state")])
print(" ".join(ids))'
}

# sheet_state: shown | hidden.
sheet_state() { if sheet_shown; then echo shown; else echo hidden; fi; }

# dkey NAME: a real key press into the focused window (detent) through casement's inject.
dkey() { casementctl debug inject "key $1 down" "sleep 30" "key $1 up" "sleep 150" >/dev/null; sleep 0.25; }

# keep_shots: copies this run's shots next to the worktree's shots dir.
HUNT_SHOTS="${HUNT_SHOTS:-$HOME/rs-wt/accounts-hunt/shots}"
