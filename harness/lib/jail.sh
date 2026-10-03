# require_jail: a structural check, not an env check (plan §6.1). Refuses (exit 2: could not run
# safely) unless /dev/input is absent, the user's wayland-0 is absent, the system bus socket is
# absent and PID 1 of this namespace is bwrap. Every scenario and dev script calls it first.
# Only stats paths and reads /proc/1/comm; it never opens a device.

# Prints every violated condition, one per line; empty when the jail holds.
jail_violations() {
  local uid; uid=$(id -u)
  [ ! -e /dev/input ] || echo "/dev/input exists"
  [ ! -e "/run/user/$uid/wayland-0" ] || echo "/run/user/$uid/wayland-0 exists"
  [ ! -e /run/dbus/system_bus_socket ] || echo "/run/dbus/system_bus_socket exists"
  [ "$(cat /proc/1/comm 2>/dev/null)" = bwrap ] || echo "PID 1 is '$(cat /proc/1/comm 2>/dev/null)', not bwrap"
}

require_jail() {
  local v; v=$(jail_violations)
  if [ -n "$v" ]; then
    echo "require_jail: refusing to run outside harness/jail.sh:" >&2
    echo "$v" | sed 's/^/  /' >&2
    exit 2
  fi
}
