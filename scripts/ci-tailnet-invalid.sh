#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
work="${PLC_REMOTE_TAILNET_WORKDIR:-$root/_build/qemu_tailnet_invalid}"
firmware="$root/_build/x86_64_dev/nerves/images/plc_remote.fw"
disk="$work/plc_remote.img"
console="$work/console.sock"
qmp="$work/qmp.sock"
log="$work/console.log"
pid=""

cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$work"
rm -f "$disk" "$console" "$qmp" "$log" "$work/qemu.log"

qemu-img create -f raw "$disk" 1G >/dev/null
fwup -a -t complete -d "$disk" -i "$firmware" >/dev/null

qemu-system-x86_64 \
  -drive "file=$disk,if=virtio,format=raw" \
  -netdev user,id=wan \
  -device virtio-net-pci,netdev=wan,id=wan0,mac=02:00:00:00:00:10,disable-legacy=on \
  -netdev hubport,id=plc,hubid=1 \
  -device virtio-net-pci,netdev=plc,id=plc0,mac=02:00:00:00:00:20,disable-legacy=on \
  -display none \
  -monitor none \
  -accel "${PLC_REMOTE_QEMU_ACCELERATOR:-tcg}" \
  -chardev "socket,id=console,path=$console,server=on,wait=on" \
  -serial chardev:console \
  -qmp "unix:$qmp,server=on,wait=off" \
  -m 1024 \
  >"$work/qemu.log" 2>&1 &
pid=$!

result="$($root/integration/qemu/console.py \
  --socket "$console" \
  --log "$log" \
  --command-timeout 120 \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.provision_ethernet_roles()))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_connection(:internet)))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.enroll_invalid_tailnet()))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_tailnet_failure()))')"

printf '%s\n' "$result"
printf '%s\n' "$result" | grep -q 'connection: :internet'
printf '%s\n' "$result" | grep -q 'auth_payload_removed: true'
printf '%s\n' "$result" | grep -q 'listener_unavailable: true'
printf '%s\n' "$result" | grep -q 'tailnet_ipv4: nil'

echo "Invalid auth key failed closed without a tailnet listener"

cleanup
trap - EXIT INT TERM
exit 0
