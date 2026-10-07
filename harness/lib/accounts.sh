# What the accounts-* scenarios share: porter's real daemons (accountd, syncd, inferd) and porter's test rig
# (porter-rig-servers: the fakes, porter-rig-secrets: a fake Secret Service, porter-rig-client: an app) on the
# private bus casement's dev/up.sh made, with sill drawing the sheets. Sourced after harness/lib/all.sh,
# harness/lib/scenario.sh and sill's dev/lib/all.sh (it uses their in_env, sill, surface_named, capture ...).
#
# Identity. The daemons are test-proc-root builds: they name the process behind a bus connection from
# $PROC/<pid>/cgroup (ACCOUNTD_PROC_ROOT, SYNCD_PROC_ROOT, INFERD_PROC_ROOT), because nothing in the jail runs
# in a systemd scope; the role of each is the caller table ($CONFIG/porter/callers.toml: porter's dist copy).
# `acc_identity UNIT PID` writes a unit's cgroup (sill-shell.scope, syncd.service, inferd.service), `acc_app APP
# PID` an app scope (org.quire.Settings for detent).
#
# Every process is stopped by its PID (acc_stop_all); nothing is found by name.

ARIG="$SCEN_BUILD/porter-target/debug"
ACC_PIDS=()
ACC_BG=()

# acc_need: the artefacts exist (exit 3 with the fix otherwise).
acc_need() {
  scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
    "$SCEN_BUILD/sill-pin-target/debug/sill" "$ARIG/accountd" "$ARIG/syncd" "$ARIG/inferd" \
    "$ARIG/porter-rig-servers" "$ARIG/porter-rig-client" "$ARIG/porter-rig-secrets" \
    "$SCEN_BUILD/pin/porter-rig/providers/microsoft.toml" "$SCEN_BUILD/pin/porter-rig/dist/callers.toml" "$@"
}

# acc_env NAME: the variables every accounts scenario sets before sourcing sill's lib.
acc_env() {
  export SILL_COMPOSITOR=casement SILL_PREBUILT=1 SILL_PROFILE=debug
  export CARGO_TARGET_DIR="$SCEN_BUILD/sill-pin-target" CASEMENT_REPO="$SCEN_SIB/casement" CASEMENT_TOOLS="$SCEN_TOOLS"
}

# Where the scenario keeps things; set by acc_dirs after scratch_new.
RIG_DIR= PROC= PROV= BIN_DIR=
acc_dirs() {
  RIG_DIR="$OUT_DIR/rig"; PROC="$RIG_DIR/proc"; PROV="$RIG_DIR/providers"; BIN_DIR="$RIG_DIR/bin"
  mkdir -p "$RIG_DIR" "$PROC" "$PROV" "$BIN_DIR" "$CONFIG/porter" "$CONFIG/quire" "$STATE/porter"
}

# acc_bg LOG CMD...: runs CMD in the background in the daemon environment with this log; sets ACC_LAST to its pid.
ACC_LAST=
acc_bg() {
  local log=$1; shift
  in_env "$@" >"$log" 2>&1 &
  ACC_LAST=$!
  ACC_PIDS+=("$ACC_LAST")
}

# acc_kill PID: ends one process we started, by its PID, and waits up to 5 s.
acc_kill() {
  kill "$1" 2>/dev/null || return 0
  for _ in $(seq 50); do kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null; return 0; }; sleep 0.1; done
  kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null
}

acc_stop_all() {
  local pid
  for pid in "${ACC_PIDS[@]:-}"; do [ -z "$pid" ] || acc_kill "$pid"; done
  ACC_PIDS=()
}

# acc_wait SECONDS CMD...: polls CMD (every 0.1 s) until it succeeds.
acc_wait() {
  local secs=$1; shift
  for _ in $(seq $(( secs * 10 ))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
  return 1
}

# bus_has_owner NAME: the name has an owner on the private bus.
bus_has_owner() {
  dbus-send --bus="$BUS" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.NameHasOwner "string:$1" 2>/dev/null | grep -q 'boolean true'
}

# --- identity ------------------------------------------------------------------------------------------------
acc_identity() { # LEAF PID: a unit's cgroup
  mkdir -p "$PROC/$2"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s\n' "$1" >"$PROC/$2/cgroup"
}
acc_app() { # APP-ID PID: a native app scope `app-<id>-1.scope`
  mkdir -p "$PROC/$2"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-%s-1.scope\n' "${1//-/\\x2d}" >"$PROC/$2/cgroup"
}

# --- the fakes -----------------------------------------------------------------------------------------------
# rig_start FLAGS...: porter-rig-servers --dir $RIG_DIR/servers FLAGS; waits for rig.json.
RIG_PID=
rig_start() {
  mkdir -p "$RIG_DIR/servers"
  acc_bg "$OUT_DIR/rig-servers.log" "$ARIG/porter-rig-servers" --dir "$RIG_DIR/servers" "$@"
  RIG_PID=$ACC_LAST
  acc_wait 20 test -s "$RIG_DIR/servers/rig.json" || { echo "porter-rig-servers never wrote rig.json:" >&2; cat "$OUT_DIR/rig-servers.log" >&2; return 1; }
}
# rigj PATH: a value of rig.json (a dotted path, `imap.port`), or the planted secrets with `secrets`.
rigj() {
  python3 -I -c '
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print("\n".join(v) if isinstance(v, list) else v)' "$RIG_DIR/servers/rig.json" "$1"
}
# rigctl METHOD TARGET [BODY]: a lever of the control endpoint; the JSON answer.
rigctl() {
  local ctl; ctl=$(rigj control) || return 1
  curl -sS -X "$1" --data-binary "${3:-}" "$ctl$2"
}

secrets_start() {
  acc_bg "$OUT_DIR/secrets.log" "$ARIG/porter-rig-secrets"
  SECRETS_PID=$ACC_LAST
  acc_wait 20 bus_has_owner org.freedesktop.secrets || { echo "the fake Secret Service never took its name" >&2; cat "$OUT_DIR/secrets.log" >&2; return 1; }
}

# --- configuration -------------------------------------------------------------------------------------------
# acc_config: the caller table (porter's own), the shipped provider files, and the person's clients file
# (acc_clients_for_issuer).
acc_config() {
  cp "$SCEN_BUILD/pin/porter-rig/dist/callers.toml" "$CONFIG/porter/callers.toml"
  cp "$SCEN_BUILD"/pin/porter-rig/providers/*.toml "$PROV/"
}

# acc_clients_for_issuer: clients.toml pointing the Microsoft client at the fake issuer.
acc_clients_for_issuer() {
  cat >"$CONFIG/porter/clients.toml" <<EOF
[[client]]
issuer = "microsoft"
channel = "stable"
client_id = "$(rigj oauth.client_id)"
[client.endpoints]
authorize = "$(rigj oauth.authorize)"
token = "$(rigj oauth.token)"
revoke = "$(rigj oauth.revoke)"
device = "$(rigj oauth.device)"
EOF
}

# graph_front_start: harness/lib/graph-front.py in front of the rig's Graph drive (the drive has no /v1.0/me, which the
# Microsoft sign-in reads); sets GRAPH_FRONT to its URL.
GRAPH_FRONT=
graph_front_start() {
  acc_bg "$OUT_DIR/graph-front.log" python3 -I "$HARNESS_LIB/graph-front.py" --upstream "$(rigj graph.url)" --port-file "$RIG_DIR/graph-front.port"
  acc_wait 10 test -s "$RIG_DIR/graph-front.port" || { echo "graph-front never listened" >&2; cat "$OUT_DIR/graph-front.log" >&2; return 1; }
  GRAPH_FRONT="http://127.0.0.1:$(cat "$RIG_DIR/graph-front.port")"
}

# acc_provider_microsoft_on_rig: the shipped microsoft.toml with Graph at the front of the rig's drive.
acc_provider_microsoft_on_rig() {
  sed -e "s#https://graph.microsoft.com#$GRAPH_FRONT#g" "$SCEN_BUILD/pin/porter-rig/providers/microsoft.toml" >"$PROV/microsoft.toml"
}

# acc_providers_only ID...: leaves only the named provider files (so the sheet's list is short).
acc_providers_only() {
  local keep=" $* " f id
  for f in "$PROV"/*.toml; do
    id=$(basename "$f" .toml)
    case "$keep" in *" $id "*) ;; *) rm -f "$f" ;; esac
  done
}

# --- the daemons ---------------------------------------------------------------------------------------------
# accountd_start: the real accountd on the private bus, over the fake Secret Service, trusting the rig's CA.
ACCOUNTD_PID=
accountd_start() {
  local ca=""
  [ ! -f "$RIG_DIR/servers/ca.pem" ] || ca="SSL_CERT_FILE=$RIG_DIR/servers/ca.pem"
  acc_bg "$OUT_DIR/accountd.log" env ACCOUNTD_PROC_ROOT="$PROC" ${ca:+"$ca"} "$ARIG/accountd" --providers "$PROV"
  ACCOUNTD_PID=$ACC_LAST
  acc_wait 20 bus_has_owner org.quire.Accounts1 || { echo "accountd never took org.quire.Accounts1:" >&2; cat "$OUT_DIR/accountd.log" >&2; return 1; }
  acc_identity accountd.service "$ACCOUNTD_PID"
}
accountd_stop() { [ -z "$ACCOUNTD_PID" ] || acc_kill "$ACCOUNTD_PID"; ACCOUNTD_PID=; }

SYNCD_PID=
syncd_start() {
  acc_bg "$OUT_DIR/syncd.log" env SYNCD_PROC_ROOT="$PROC" "$ARIG/syncd"
  SYNCD_PID=$ACC_LAST
  acc_identity syncd.service "$SYNCD_PID"
  acc_wait 20 bus_has_owner org.quire.Sync1 || { echo "syncd never took org.quire.Sync1:" >&2; cat "$OUT_DIR/syncd.log" >&2; return 1; }
}
syncd_stop() { [ -z "$SYNCD_PID" ] || acc_kill "$SYNCD_PID"; SYNCD_PID=; }

INFERD_PID=
inferd_start() { # [extra inferd.toml text on stdin was written by the caller to $CONFIG/quire/inferd.toml]
  acc_bg "$OUT_DIR/inferd.log" env INFERD_PROC_ROOT="$PROC" "$ARIG/inferd"
  INFERD_PID=$ACC_LAST
  acc_identity inferd.service "$INFERD_PID"
  acc_wait 20 bus_has_owner org.quire.Inference1 || { echo "inferd never took org.quire.Inference1:" >&2; cat "$OUT_DIR/inferd.log" >&2; return 1; }
}

# sill_start: sill (the sheet host) on the same bus; its pid is named sill-shell.scope, the sheet host's unit.
sill_start() {
  cat >"$BIN_DIR/xdg-open" <<EOF
#!/usr/bin/env bash
# The scenario's browser: records the address, then follows it (redirects included) the way a person's
# browser would; the issuer's consent is a lever of the rig.
echo "\$1" >>"$RIG_DIR/opened.log"
curl -sL --max-time 10 -o "$RIG_DIR/browser-last.html" "\$1" >>"$RIG_DIR/browser.log" 2>&1
EOF
  chmod +x "$BIN_DIR/xdg-open"
  mkdir -p "$CONFIG/sill"; : >"$CONFIG/sill/settings.toml"
  backdrop_seed "$CONFIG" || return 1
  IN_ENV_EXTRA=("PATH=$BIN_DIR:$PATH")
  launch_daemon || return 1
  acc_identity sill-shell.scope "$DAEMON"
  NAME=$(output_name) || return 1
  SHEET="sill-accounts-sheet-$NAME"
}

# --- an app --------------------------------------------------------------------------------------------------
# rigc APP-ID ARGS...: porter-rig-client as that app (its identity is written before it connects).
rigc() {
  local app=$1; shift
  in_env "$ARIG/porter-rig-client" --app-id "$app" --proc-root "$PROC" "$@"
}
# rigc_bg LOG APP-ID ARGS...: the same in the background; sets ACC_LAST to its pid.
rigc_bg() {
  local log=$1 app=$2; shift 2
  acc_bg "$log" "$ARIG/porter-rig-client" --app-id "$app" --proc-root "$PROC" "$@"
}

# --- the sheet, as sill draws it -----------------------------------------------------------------------------
# sheet_shown: the sheet's surface draws something now.
sheet_shown() {
  sill debug capture "$SHEET" "$OUT_DIR/.probe.png" >/dev/null 2>&1 && [ "$(opaque_pixels "$OUT_DIR/.probe.png")" -gt 1000 ]
}
sheet_hidden() { ! sheet_shown; }
sheet_await() { acc_wait "${1:-15}" sheet_shown || { echo "the sheet never showed" >&2; return 1; }; }
sheet_gone() { acc_wait "${1:-15}" sheet_hidden || { echo "the sheet never went" >&2; return 1; }; }
# sheet_shot NAME: a capture of the sheet into the scenario's output dir.
sheet_shot() { sill debug capture "$SHEET" "$OUT_DIR/$1.png" >>"$OUT_DIR/capture.log" 2>&1; }
sheet_key() { sill debug key "$SHEET" "$1" >>"$OUT_DIR/keys.log" 2>&1; }
# sheet_type TEXT: typed through the compositor (casementctl debug inject "type TEXT": each character, with Shift where
# the keymap needs it). `sill debug key` cannot type '@' (shell-host's key_spec has no code for it), and the sheet
# holds the keyboard focus, so the compositor's own input reaches its field.
sheet_type() { casementctl debug inject "type $1" >>"$OUT_DIR/keys.log" 2>&1; }

# --- a record of the bus -------------------------------------------------------------------------------------
MONITOR_PID=
monitor_start() {
  busctl --address="$BUS" monitor --json=short >"$OUT_DIR/bus.jsonl" 2>"$OUT_DIR/bus-monitor.err" &
  MONITOR_PID=$!
  ACC_PIDS+=("$MONITOR_PID")
}
monitor_stop() { [ -z "$MONITOR_PID" ] || acc_kill "$MONITOR_PID"; MONITOR_PID=; }

# --- asking accountd as an app, with nothing but busctl ------------------------------------------------------
# as_app APP-ID CMD...: runs CMD as a process that accountd names APP-ID (a Flatpak scope written for the shell's
# own pid before the exec, so the pid the bus reports is the command's), then removes the identity.
as_app() {
  local app=$1; shift
  in_env bash -c '
    app=$1; proc=$2; shift 2
    esc=$(printf %s "$app" | sed "s/-/\\\\x2d/g")
    mkdir -p "$proc/$$"
    printf "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-%s-$$.scope\n" "$esc" >"$proc/$$/cgroup"
    exec "$@"' _ "$app" "$PROC" "$@"
}

# settings_describe: accountd's settings module schema (JSON), read as the Settings app.
settings_describe() {
  as_app org.quire.Settings busctl --address="$BUS" --json=short call org.quire.Accounts1 /org/quire/Accounts1/settings \
    org.quire.SettingsModule1 Describe | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"][0])'
}
# settings_get KEY: a key's current value as the bus prints it (`--json=short`: {"type":"v","data":[...]}), data only.
settings_get() {
  as_app org.quire.Settings busctl --address="$BUS" --json=short call org.quire.Accounts1 /org/quire/Accounts1/settings \
    org.quire.SettingsModule1 Get s "$1" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"][0]
while isinstance(d, dict) and "data" in d: d = d["data"]
print(d)'
}

# --- the generic mail account of scenarios 1, 4 and 9 -------------------------------------------------------
# acc_fake_mail_provider: a brand file (discovery fixed) that names the rig's IMAP and SMTP servers. The generic
# provider (`generic-imap`, "Other...") cannot reach a fake in the jail: it finds servers by autoconfig over HTTPS
# on port 443 and, failing that, asks for a host and dials 993 and 587, ports the jail cannot bind.
# Needs the rig started with --imap --smtp --tls implicit.
acc_fake_mail_provider() {
  cat >"$PROV/fake-mail.toml" <<EOT
id = "fake-mail"
label = "Fake Mail"
mark = "mail"

[auth]
kind = "password"

[discovery]
kind = "fixed"

[[capability]]
family = "imap"
endpoint = "imaps://127.0.0.1:$(rigj imap.port)"
kind = "mail"
v = { access = "read_write", send = "present", delta = "poll", transport = "imap", labels = "folders" }

[[capability]]
family = "smtp"
endpoint = "smtps://127.0.0.1:$(rigj smtp.port)"
kind = "mail"
v = { access = "read_write", send = "present", delta = "poll", transport = "imap", labels = "folders" }
EOT
}

# acc_add_start APP-ID: AddAccount as that app, in the background (its Response lands in $OUT_DIR/add.log).
acc_add_start() {
  : >"$OUT_DIR/add.log"
  acc_bg "$OUT_DIR/add.log" python3 -I "$HARNESS_LIB/accounts-app.py" --bus "$BUS" --proc "$PROC" --app "$1" add-account "${2:-}"
  ADD_PID=$ACC_LAST
}
# acc_add_response: waits for the Response line of acc_add_start and prints it.
acc_add_response() {
  acc_wait "${1:-30}" grep -q '"response"' "$OUT_DIR/add.log" || return 1
  grep '"response"' "$OUT_DIR/add.log" | tail -n 1
}
HARNESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- the secret scan -----------------------------------------------------------------------------------------
# scan_begin: records the private bus from now on (call it before the daemons start, so the names' owners are seen).
# scan_end: stops the record and runs harness/lib/secret-scan.py over it, the scenario's logs and the state, config
# and data trees of the scratch HOME for every secret the rig planted and the issuer's minted tokens. 0 clean.
scan_begin() { monitor_start; sleep 0.5; }
scan_end() {
  local args=() s files=()
  sleep 0.5; monitor_stop
  # What accountd kept (the registry and the audit file), for whoever reads the run afterwards.
  rm -rf "$OUT_DIR/state-after"; cp -r "$STATE" "$OUT_DIR/state-after" 2>/dev/null
  while read -r s; do
    [ -n "$s" ] || continue
    case "$s" in *ACCESS-TOKEN*) args+=(--access-secret "$s") ;; *) args+=(--secret "$s") ;; esac
  done < <(rigj secrets 2>/dev/null)
  local f
  for f in "$OUT_DIR"/*.log; do
    case "$(basename "$f")" in keys.log|input.log|rig-servers.log) ;; *) files+=(--file "$f") ;; esac
  done
  python3 -I "$HARNESS_LIB/secret-scan.py" --bus "$OUT_DIR/bus.jsonl" "${args[@]}" \
    --pattern 'fake-refresh-[0-9]+' --pattern 'fake-code-[0-9]+' --access-pattern 'fake-access-[0-9]+' \
    "${files[@]}" --dir "$STATE" --dir "$CONFIG" --dir "$DATA" --report "$OUT_DIR/secret-scan.txt"
}

# sheet_add_fake_mail [SHOT-PREFIX]: the whole add flow of the fake mail account through the sheet as an app asks
# for it (the steps accounts-generic-mail checks one by one); the account is `fake-mail-ada-rig.test`.
sheet_add_fake_mail() {
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type Fake; sleep 0.5; sheet_key Enter; sleep 1
  sheet_type "$(rigj imap.user)"; sheet_key Tab; sheet_type "$(rigj imap.password)"; sleep 0.5
  sheet_key Enter; sleep 2
  sheet_key Enter
  local response
  response=$(acc_add_response 30) || { echo "AddAccount never answered: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  case "$response" in '{"response": 0'*) ;; *) echo "AddAccount answered $response" >&2; return 1 ;; esac
  sheet_gone
}

# sheet_add_microsoft: the whole browser sign-in through the sheet as an app asks for it (accounts-oauth-browser checks
# the steps one by one); needs the rig started with --graph, graph_front_start, acc_clients_for_issuer and
# acc_provider_microsoft_on_rig. Sets ACCOUNT to the account's id.
sheet_add_microsoft() {
  : >"$RIG_DIR/opened.log"
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type Micro; sleep 0.5; sheet_key Enter
  acc_wait 20 test -s "$RIG_DIR/opened.log" || { echo "sill never opened the browser: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  sleep 3; sheet_key Enter
  local response
  response=$(acc_add_response 30) || { echo "AddAccount never answered: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  case "$response" in '{"response": 0'*) ;; *) echo "AddAccount answered $response" >&2; return 1 ;; esac
  ACCOUNT=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["results"]["account"])' "$response")
  sheet_gone
}

# sheet_grant APP NEED CLASS LOG: the app asks (request-grant) and the person answers Always Allow.
sheet_grant() {
  rigc_bg "$OUT_DIR/$4.log" "$1" request-grant "$2" --class "$3"
  sheet_await || { cat "$OUT_DIR/$4.log" >&2; return 1; }
  sleep 1; sheet_key Tab; sheet_key Enter
  acc_wait 20 grep -q '"result"' "$OUT_DIR/$4.log" || { echo "request-grant never answered" >&2; return 1; }
  grep -q '"result":"granted"' "$OUT_DIR/$4.log" || { cat "$OUT_DIR/$4.log" >&2; return 1; }
  sheet_gone
}

# detent_start: detent (the Settings app, built at its pin) on casement, on the private bus, named org.quire.Settings
# (the role `settings` of the caller table). Its window is captured with `casementctl shot --output` (acc_shot).
DETENT_PID=
detent_start() {
  local data="$SCRATCH/detent-data"
  # The programs' schemas, as detent's own tests seed them (its pages are made of schemas: without them the sidebar
  # lists only Accounts).
  mkdir -p "$data/quire/settings" "$STATE/detent"
  cp "$SCEN_BUILD"/pin/detent/fixtures/schemas/*.toml "$data/quire/settings/"
  # --first-run is skipped: the mark says it ran.
  echo ran >"$STATE/detent/first-run"
  # Not through `nested` (a function: the background job would be its subshell, not detent, and the identity written
  # below must be for the process that holds the bus connection).
  env WAYLAND_DISPLAY="$WL" XDG_RUNTIME_DIR="$(dirname "$WL")" HOME="$HOME_DIR" XDG_CONFIG_HOME="$CONFIG" XDG_DATA_HOME="$data" XDG_DATA_DIRS="$data" XDG_STATE_HOME="$STATE" \
    XDG_CACHE_HOME="$CACHE" DBUS_SESSION_BUS_ADDRESS="$BUS" "$SCEN_BUILD/detent-target/debug/detent" >"$OUT_DIR/detent.log" 2>&1 &
  DETENT_PID=$!
  ACC_PIDS+=("$DETENT_PID")
  acc_app org.quire.Settings "$DETENT_PID"
}

# acc_shot NAME: the whole output, as the compositor composes it (casementctl shot --output).
acc_shot() { casementctl shot --output HEADLESS-1 "$OUT_DIR/$1.png" >>"$OUT_DIR/shot.log" 2>&1; }

# detent_frame: "X Y W H" of detent's window in the output (casementctl debug windows, the first window).
detent_frame() {
  casementctl debug windows | python3 -I -c '
import json, sys
w = json.load(sys.stdin)
print(*[int(v) for v in w[0]["frame"]])'
}
# detent_click RX RY: a left click at (RX, RY) relative to detent's window origin (the pointer is moved first and
# given a moment: detent's hover state must catch up before a press counts).
detent_click() {
  local x y w h
  read -r x y w h < <(detent_frame) || return 1
  casementctl debug inject "move $((x + $1)) $((y + $2))" >/dev/null || return 1
  casementctl debug wait settled --timeout 10000 >/dev/null 2>&1
  sleep 0.3
  casementctl debug inject "press left" "release left" >/dev/null || return 1
  sleep 0.7
}

# detent_focus: the first press into a window only focuses it (detent's own grab zones take the next), so one harmless
# click on the title bar's text makes the following clicks count.
detent_focus() { detent_click 450 14; }

# acc_seed_grant APP ISOLATION ACCOUNT KIND CLASS USAGE: an Allow/Always grant put in the registry while accountd is
# stopped (it is started again). A daemon cannot draw a consent sheet and nothing in Settings offers syncd's grant yet
# (porter FINDINGS, "syncd storage: the grant that makes a mirror ..."), so the owner's act is seeded the way porter's
# own tests seed it.
acc_seed_grant() {
  accountd_stop
  python3 -I - "$STATE/porter/registry.json" "$@" <<'PY' || return 1
import json, sys, time
path, app, iso, account, kind, cls, usage = sys.argv[1:8]
d = json.load(open(path))
n = len(d["grants"]) + 1
d["grants"].append({
    "id": "seeded-%d" % n,
    "key": {"app": {"name": app, "isolation": iso}, "account": account, "kind": kind, "class": cls,
            "usage": usage, "space": {"kind": "any"}},
    "decision": "allow", "scope": "always", "at": int(time.time())})
json.dump(d, open(path, "w"))
PY
  accountd_start
}

# sheet_settled: the sheet's drawing has stopped changing (two captures 0.6 s apart are the same): its first animation
# and the focus on its search field are done, so typed keys land.
sheet_settled() {
  local i
  for i in $(seq 30); do
    sheet_shot .settle-a; sleep 0.6; sheet_shot .settle-b
    [ "$(changed_fraction "$OUT_DIR/.settle-a.png" "$OUT_DIR/.settle-b.png")" = 0.0 ] && return 0
    [[ "$(changed_fraction "$OUT_DIR/.settle-a.png" "$OUT_DIR/.settle-b.png")" == 0.000* ]] && return 0
  done
  return 1
}

# acc_provider_openai_on_rig: the shipped openai.toml with its API at the rig's LLM API fake (needs --llm-api).
acc_provider_openai_on_rig() {
  sed -e "s#https://api.openai.com/v1#$(rigj llm_api.api_url)#" "$SCEN_BUILD/pin/porter-rig/providers/openai.toml" >"$PROV/openai.toml"
}
