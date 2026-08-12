#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
work="${PLC_REMOTE_QEMU_WORKDIR:-$root/_build/qemu_test}"
firmware="$root/_build/x86_64_dev/nerves/images/plc_remote.fw"
disk="$work/plc_remote.img"
console="$work/console.sock"
qmp="$work/qmp.sock"
log="$work/console.log"
qemu_log="$work/qemu.log"
pid=""
qemu_accelerator="${PLC_REMOTE_QEMU_ACCELERATOR:-tcg}"
qemu_helper="$root/test/support/qemu_cli.exs"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing firmware test dependency: $1" >&2
    exit 1
  }
}

cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  pid=""
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in elixir fwup qemu-img qemu-system-x86_64; do
  require "$command"
done

mkdir -p "$work"
rm -f "$disk" "$console" "$qmp" "$log" "$qemu_log"

if [ "${PLC_REMOTE_QEMU_SKIP_BUILD:-0}" != "1" ]; then
  "$root/test/firmware/build.sh" build
fi

"$root/test/firmware/build.sh" inspect
qemu-img create -f raw "$disk" 1G >/dev/null
fwup -a -t complete -d "$disk" -i "$firmware" >/dev/null

# QEMU's guestfwd runs /bin/cat for each PLC-side TCP connection. This is the
# whole echo fixture; no separate server or extra language is needed.
plc_netdev="user,id=plc,net=192.168.10.0/24,restrict=on,guestfwd=tcp:192.168.10.100:10102-cmd:/bin/cat"

start_vm() {
  rm -f "$console" "$qmp"

  qemu-system-x86_64 \
    -drive "file=$disk,if=virtio,format=raw" \
    -netdev user,id=wan \
    -device virtio-net-pci,netdev=wan,id=wan0,mac=02:00:00:00:00:10,disable-legacy=on \
    -netdev "$plc_netdev" \
    -device virtio-net-pci,netdev=plc,id=plc0,mac=02:00:00:00:00:20,disable-legacy=on \
    -display none \
    -monitor none \
    -accel "$qemu_accelerator" \
    -chardev "socket,id=console,path=$console,server=on,wait=on" \
    -serial chardev:console \
    -qmp "unix:$qmp,server=on,wait=off" \
    -m 1024 \
    >>"$qemu_log" 2>&1 &
  pid=$!
}

console_run() {
  elixir "$qemu_helper" console "$console" "$log" "$@"
}

set_link() {
  elixir "$qemu_helper" link "$qmp" plc0 "$1"
}

start_vm

result="$(console_run \
  'IO.puts(PlcRemote.Integration.result(%{health: PlcRemote.Integration.health(), interfaces: PlcRemote.Integration.interfaces(), nif: PlcRemote.Integration.nif_smoke()}))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.provision_ethernet_roles()))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_connection(:internet)))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.plc_echo()))')"
printf '%s\n' "$result"
printf '%s\n' "$result" | grep -q 'application: true'
printf '%s\n' "$result" | grep -q 'nif_loaded: true'
printf '%s\n' "$result" | grep -q 'internet_uplink: "eth0"'
printf '%s\n' "$result" | grep -q 'machine_lan: "eth1"'
printf '%s\n' "$result" | grep -q 'connection: :internet'
printf '%s\n' "$result" | grep -q 'payload: "plc-remote-qemu"'

set_link down
link_down="$(console_run 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_interface_link("02:00:00:00:00:20", false)))')"
printf '%s\n' "$link_down" | grep -q 'lower_up: false'

set_link up
link_up="$(console_run 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_interface_link("02:00:00:00:00:20", true)))')"
printf '%s\n' "$link_up" | grep -q 'lower_up: true'

poweroff="$(console_run 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.schedule_poweroff()))')"
printf '%s\n' "$poweroff" | grep -q 'PLC_REMOTE_CI::ok'

for _attempt in $(seq 1 200); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done

if kill -0 "$pid" 2>/dev/null; then
  echo "QEMU did not stop after guest poweroff" >&2
  exit 1
fi
wait "$pid" 2>/dev/null || true
pid=""

start_vm
persisted="$(console_run 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.persistent_status()))')"
printf '%s\n' "$persisted"
printf '%s\n' "$persisted" | grep -q 'internet_uplink: "eth0"'
printf '%s\n' "$persisted" | grep -q 'machine_lan: "eth1"'
printf '%s\n' "$persisted" | grep -q 'plc_address: "192.168.10.100"'

echo "Firmware test passed: boot, NIF, dual Ethernet, PLC echo, link changes, and persistence"

cleanup
trap - EXIT INT TERM
