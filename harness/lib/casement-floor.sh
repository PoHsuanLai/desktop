# What every scenario's casement is told about the programs it will see (design 3.8, the owner's "ask per app").
#
# casement asks the person the first time a program watches the screen, types, reads the clipboard, lists
# windows, uses an input method, locks the screen or changes the displays. Nobody answers inside a scenario, so
# a scenario starts its casement with `--system-dir DIR` (a debug build reads it as the administrator's floor,
# owned by the running user) and a floor of `allow` rows for exactly the programs its steps run. This file is the
# one place that writes the floor; no scenario writes privacy.toml itself.
#
#   floor_make NAME [TOOL...]   writes the floor for NAME; sets FLOOR_DIR. No TOOL is a floor with no rows, which
#                               is right for a scenario whose programs use no power (the shell, the apps)
#   floor_shim NAME [TOOL...]   floor_make, then points CASEMENT_REPO and CASEMENT_DIR at a stand-in checkout
#                               whose dev/up.sh adds `--system-dir` and whose dev/down.sh is casement's own. For
#                               scripts that start casement themselves (sill's and shell-host's libraries, whose
#                               pins may predate the flag): they call "$CASEMENT_REPO/dev/up.sh" and never see
#                               the difference. The flag is added last, so this floor is the one casement reads
#
# A floor row names a program by its image, so only a program the system owns can be named: a program built under
# build/ (sill, detent, transom, the demos) is judged by casement as one it cannot vouch for and is asked every
# time, whatever the floor says. A scenario that needs one of those answered needs casement's help (FINDINGS).
#
# Display changes: a program that changes the outputs (wlr-randr and the like) is asked by casement whether to keep
# the new setup and the change goes back after 15 s (quire_shell_v1 version 6). No scenario does that: the scale
# and size changes they make go through `casementctl debug output set`, the compositor's own test control. A
# scenario that does change outputs through a program must answer Keep through the shell or expect the revert.

# floor_powers TOOL: the powers TOOL takes on casement's socket, space separated; fails for a tool not listed.
floor_powers() {
  case "$1" in
    grim | wf-recorder | wayshot) echo screen ;;
    wl-copy | wl-paste | cliphist) echo clipboard ;;
    wtype) echo keys ;;
    fcitx5) echo typing_help keys ;; # the input method, and the virtual keyboard it forwards keys through
    wlr-randr | kanshi) echo displays ;;
    wlrctl | lswt) echo windows ;;
    swaylock) echo lock ;;
    *) return 1 ;;
  esac
}

# floor_rows TOOL...: one allow row per power of each TOOL that is installed (a tool that is not installed is left
# out: the step that needs it says so). Fails for a tool floor_powers does not know.
floor_rows() {
  local tool power path
  for tool in "$@"; do
    floor_powers "$tool" >/dev/null || { echo "floor_rows: no powers are known for $tool (add it to floor_powers)" >&2; return 2; }
    path=$(command -v "$tool" 2>/dev/null) && path=$(readlink -f "$path") || continue
    for power in $(floor_powers "$tool"); do
      printf '\n[[rule]]\npower = "%s"\nsubject = { program = "%s" }\nanswer = "allow"\n' "$power" "$path"
    done
  done
}

# floor_make NAME [TOOL...]: the floor in $JAIL_SCRATCH/casement-floor/NAME (a folder only this user can enter, with
# privacy.toml in it: the shape casement's floor file reads); sets FLOOR_DIR.
FLOOR_DIR=
floor_make() {
  local name=$1 dir rows
  shift
  dir="${JAIL_SCRATCH:?floor_make: not in the jail}/casement-floor/$name"
  rows=$(floor_rows "$@") || return 1
  rm -rf "$dir" && mkdir -p "$(dirname "$dir")" && mkdir -m 700 "$dir" || return 1
  { echo "# The floor of scenario $name: the programs its steps run (harness/lib/casement-floor.sh)."; echo "$rows"; } >"$dir/privacy.toml" || return 1
  chmod 600 "$dir/privacy.toml" || return 1
  FLOOR_DIR=$dir
}

# floor_shim NAME [TOOL...]: floor_make, then the stand-in checkout (see the top of this file).
floor_shim() {
  local real="${SCEN_SIB:?floor_shim: scenario.sh is not sourced}/casement" repo
  floor_make "$@" || return 1
  repo="$FLOOR_DIR.repo"
  rm -rf "$repo" && mkdir -p "$repo/dev" || return 1
  printf '#!/usr/bin/env bash\nexec %q/dev/up.sh "$@" --system-dir %q\n' "$real" "$FLOOR_DIR" >"$repo/dev/up.sh" || return 1
  printf '#!/usr/bin/env bash\nexec %q/dev/down.sh "$@"\n' "$real" >"$repo/dev/down.sh" || return 1
  chmod 700 "$repo/dev/up.sh" "$repo/dev/down.sh" || return 1
  export CASEMENT_REPO=$repo CASEMENT_DIR=$repo
}
