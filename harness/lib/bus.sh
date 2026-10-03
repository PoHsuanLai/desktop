# A private dbus-daemon acting as both session and system bus (private-bus.conf: no service
# dirs, so nothing is ever activated). Jail only: the real buses are never reached.
# shellcheck source=jail.sh
source "$(dirname "${BASH_SOURCE[0]}")/jail.sh"

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_BUS_PID=

# Starts the bus and exports DBUS_SESSION_BUS_ADDRESS and DBUS_SYSTEM_BUS_ADDRESS (both private).
private_bus_start() {
  require_jail
  local out
  out=$(dbus-daemon --config-file "$HARNESS_DIR/private-bus.conf" --fork --print-address --print-pid) || return 1
  DBUS_SESSION_BUS_ADDRESS=$(printf '%s\n' "$out" | sed -n 1p)
  PRIVATE_BUS_PID=$(printf '%s\n' "$out" | sed -n 2p)
  DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS
  export DBUS_SESSION_BUS_ADDRESS DBUS_SYSTEM_BUS_ADDRESS
}

private_bus_stop() {
  [ -z "$PRIVATE_BUS_PID" ] || kill "$PRIVATE_BUS_PID" 2>/dev/null || true
  PRIVATE_BUS_PID=
}
