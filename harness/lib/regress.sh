# What the accounts-regress-* scenarios share (on top of harness/lib/accounts.sh): checks that fail the step, the sheet's
# traffic read from the recorded bus, and measurements of a capture. Sourced after accounts.sh.
#
# How a sheet is observed. sill draws it through shell-host, which never runs ds-blitz's debug probe (QUIRE_DEBUG_PROBE
# writes nothing for any sill surface: only a window of a quire app does), so there is no list of its controls. What is
# read instead: what accountd tells it (Open/Update, the SheetView) and what the person's keys made it send back (Input),
# both in the bus record (sheet-bus.py); and the capture of its surface (pixels.py): where the card is, whether two
# captures are the same pixels, where the dark text lies. Text is never read: a text check compares two captures that
# differ only in what is being tested.

REG_FAILS=0

# must WHAT CMD...: runs CMD; a failure prints the regression and counts (the step ends with reg_verdict).
must() {
  local what=$1; shift
  if "$@"; then echo "ok   $what" >&2; else echo "FAIL $what" >&2; REG_FAILS=$(( REG_FAILS + 1 )); return 1; fi
}
# reg_verdict: the step's code: 1 when any check failed so far.
reg_verdict() { [ "$REG_FAILS" = 0 ]; }
# not CMD...: the negation, for must.
not() { ! "$@"; }

# px ARGS...: pixels.py.
px() { python3 -I "$HARNESS_LIB/pixels.py" "$@"; }

# bus_count: how many sheet messages the bus record holds. bus_since N: those after the first N (INDEX KIND JSON per line).
bus_count() { python3 -I "$HARNESS_LIB/sheet-bus.py" "$OUT_DIR/bus.jsonl" --count; }
bus_since() { python3 -I "$HARNESS_LIB/sheet-bus.py" "$OUT_DIR/bus.jsonl" --from "$1"; }
# bus_saw N PATTERN: a sheet message after the first N holds this fixed text (`input {"kind":"dismiss"}`).
bus_saw() { bus_since "$1" | grep -qF -- "$2"; }
# last_pick N: the provider the person picked after the first N messages.
last_pick() { bus_since "$1" | sed -n 's/.* input {"kind":"pick","v":"\([^"]*\)"}$/\1/p' | tail -n 1; }

# open_sheet: the add-account sheet as an app asks for it, drawn and still.
open_sheet() { acc_add_start org.quire.Mail; sheet_await || return 1; sheet_settled; sleep 0.5; }
# close_sheet: Escape until the sheet is gone, and the asking app ended.
close_sheet() {
  local i
  for i in 1 2 3; do sheet_shown || break; sheet_key Escape; sleep 0.8; done
  kill "${ADD_PID:-}" 2>/dev/null; sheet_gone 5
}
# sheet_card SHOT: the card's box in the sheet's capture of that name ("X0 Y0 X1 Y1 W H").
sheet_card() { px card "$OUT_DIR/$1.png"; }
# card_top SHOT: the card's top band (its title), as a box for px.
card_top() { local x0 y0 x1; read -r x0 y0 x1 _ < <(sheet_card "$1") || return 1; echo "$x0,$y0,$x1,$((y0 + 32))"; }
# same_shot A B [BOX]: two captures draw the same pixels (in the box).
same_shot() { px same "$OUT_DIR/$1.png" "$OUT_DIR/$2.png" ${3:+--box "$3"} >/dev/null; }

# ask APP LOG: an app asks for Mail (request-grant) in the background; the answer lands in LOG.
ask() { rigc_bg "$OUT_DIR/$2.log" "$1" request-grant mail --class mail; }

# provider_copy ID LABEL FROM: a provider file like FROM (a brand file in $PROV) under another id and label.
provider_copy() {
  sed -e "s/^id = .*/id = \"$1\"/" -e "s/^label = .*/label = \"$2\"/" "$PROV/$3.toml" >"$PROV/$1.toml"
}

# regress_boot: casement, the recorded bus, the rig (mail, and Graph for Microsoft), Secret Service, accountd, sill.
regress_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  [ -z "${REGRESS_THEME:-}" ] || printf '[appearance]\ntheme = "%s"\n' "$REGRESS_THEME" >"$CONFIG/quire/appearance.toml"
  scan_begin
  rig_start --graph --imap --smtp --tls implicit || return 1
  secrets_start || return 1
  acc_config; acc_fake_mail_provider
}

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

# detent_mapped: detent's window is up.
detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }
# dkey NAME: a real key press into the focused window (detent) through casement's inject.
dkey() { casementctl debug inject "key $1 down" "sleep 30" "key $1 up" "sleep 150" >/dev/null; sleep 0.25; }
