#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
work="${PLC_REMOTE_QEMU_WORKDIR:-$root/_build/qemu_integration}"
firmware="$root/_build/x86_64_dev/nerves/images/plc_remote.fw"
disk="$work/plc_remote.img"
console="$work/console.sock"
qmp="$work/qmp.sock"
log="$work/console.log"
qemu_log="$work/qemu.log"
pid=""
plc_pid=""
plc_fixture_port=""
plc_fixture_port_file="$work/plc-fixture.port"
qemu_accelerator="${PLC_REMOTE_QEMU_ACCELERATOR:-tcg}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing integration dependency: $1" >&2
    exit 1
  }
}

cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  if [ -n "$plc_pid" ] && kill -0 "$plc_pid" 2>/dev/null; then
    kill "$plc_pid" 2>/dev/null || true
    wait "$plc_pid" 2>/dev/null || true
  fi

  pid=""
  plc_pid=""
  return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in fwup python3 qemu-img qemu-system-x86_64; do
  require "$command"
done

mkdir -p "$work"
rm -f "$disk" "$console" "$qmp" "$log" "$qemu_log" "$plc_fixture_port_file"

plc_netdev="hubport,id=plc,hubid=1"

if [ "${PLC_REMOTE_QEMU_PLC_FIXTURE:-0}" = "1" ]; then
  python3 "$root/integration/qemu/plc_fixture.py" "$plc_fixture_port_file" \
    >"$work/plc-fixture.log" 2>&1 &
  plc_pid=$!

  for _attempt in $(seq 1 50); do
    [ -s "$plc_fixture_port_file" ] && break
    sleep 0.1
  done

  if [ ! -s "$plc_fixture_port_file" ]; then
    echo "PLC fixture did not publish its port" >&2
    exit 1
  fi

  plc_fixture_port="$(cat "$plc_fixture_port_file")"
  plc_netdev="user,id=plc,net=192.168.10.0/24,restrict=on,guestfwd=tcp:192.168.10.100:10102-tcp:127.0.0.1:$plc_fixture_port"
fi

if [ "${PLC_REMOTE_QEMU_SKIP_BUILD:-0}" != "1" ]; then
  "$root/scripts/ci-x86.sh" build
fi

"$root/scripts/ci-x86.sh" inspect
qemu-img create -f raw "$disk" 1G >/dev/null
fwup -a -t complete -d "$disk" -i "$firmware" >/dev/null

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
  >"$qemu_log" 2>&1 &
pid=$!

result="$($root/integration/qemu/console.py \
  --socket "$console" \
  --log "$log" \
  'IO.puts(PlcRemote.Integration.result(%{health: PlcRemote.Integration.health(), interfaces: PlcRemote.Integration.interfaces(), nif: PlcRemote.Integration.nif_smoke()}))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.provision_ethernet_roles()))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_connection(:internet)))')"

printf '%s\n' "$result"
printf '%s\n' "$result" | grep -q 'application: true'
printf '%s\n' "$result" | grep -q 'nif_loaded: true'
printf '%s\n' "$result" | grep -q '02:00:00:00:00:10'
printf '%s\n' "$result" | grep -q '02:00:00:00:00:20'
printf '%s\n' "$result" | grep -q 'internet_uplink: "eth0"'
printf '%s\n' "$result" | grep -q 'machine_lan: "eth1"'
printf '%s\n' "$result" | grep -q 'connection: :internet'

if [ "${PLC_REMOTE_QEMU_PLC_FIXTURE:-0}" = "1" ]; then
  plc_result="$($root/integration/qemu/console.py \
    --socket "$console" \
    --log "$log" \
    'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.plc_echo()))')"
  printf '%s\n' "$plc_result"
  printf '%s\n' "$plc_result" | grep -q 'payload: "plc-remote-qemu"'
fi

"$root/integration/qemu/qmp.py" --socket "$qmp" --device plc0 --down
link_down="$($root/integration/qemu/console.py \
  --socket "$console" \
  --log "$log" \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_interface_link("02:00:00:00:00:20", false)))')"
printf '%s\n' "$link_down"
printf '%s\n' "$link_down" | grep -q 'lower_up: false'

"$root/integration/qemu/qmp.py" --socket "$qmp" --device plc0 --up
link_up="$($root/integration/qemu/console.py \
  --socket "$console" \
  --log "$log" \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_interface_link("02:00:00:00:00:20", true)))')"
printf '%s\n' "$link_up"
printf '%s\n' "$link_up" | grep -q 'lower_up: true'

# Ask Nerves to shut down so the guest flushes /data, then restart without
# reflashing the disk.
poweroff_result="$($root/integration/qemu/console.py \
  --socket "$console" \
  --log "$log" \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.schedule_poweroff()))')"
printf '%s\n' "$poweroff_result"
printf '%s\n' "$poweroff_result" | grep -q 'PLC_REMOTE_CI::ok'

for _attempt in $(seq 1 200); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done

if kill -0 "$pid" 2>/dev/null; then
  echo "QEMU did not stop after ACPI powerdown" >&2
  exit 1
fi

wait "$pid" 2>/dev/null || true
pid=""
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

persisted="$($root/integration/qemu/console.py \
  --socket "$console" \
  --log "$log" \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.persistent_status()))')"
printf '%s\n' "$persisted"
printf '%s\n' "$persisted" | grep -q 'internet_uplink: "eth0"'
printf '%s\n' "$persisted" | grep -q 'machine_lan: "eth1"'
printf '%s\n' "$persisted" | grep -q 'plc_address: "192.168.10.100"'

echo "QEMU Nerves boot, persistent settings, Internet Ethernet, dual roles, observed link cycling, optional PLC echo, and tailscale-rs NIF smoke passed"

# dash, used as /bin/sh on Ubuntu CI, can propagate a trap's last command
# status differently from local shells. Make successful teardown explicit.
cleanup
trap - EXIT INT TERM
exit 0
