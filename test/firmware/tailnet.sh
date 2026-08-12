#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
work="${PLC_REMOTE_TAILNET_WORKDIR:-$root/_build/qemu_tailnet}"
firmware="$root/_build/x86_64_dev/nerves/images/plc_remote.fw"
enrollment="${PLC_REMOTE_TAILNET_ENROLLMENT_FILE:?set PLC_REMOTE_TAILNET_ENROLLMENT_FILE}"
ssh_key="${PLC_REMOTE_TAILNET_SSH_KEY:-$HOME/.ssh/id_ed25519}"
disk="$work/plc_remote.img"
console="$work/console.sock"
log="$work/console.log"
qemu_log="$work/qemu.log"
qemu_accelerator="${PLC_REMOTE_QEMU_ACCELERATOR:-tcg}"
remote_enrollment="/tmp/plc-remote-tailnet-enrollment.json"
ssh_port="${PLC_REMOTE_TAILNET_SSH_PORT:-10022}"
pid=""

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing live-tailnet dependency: $1" >&2
    exit 1
  }
}

cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  pid=""
  return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in elixir fwup qemu-img qemu-system-x86_64 sftp ssh tailscale timeout; do
  require "$command"
done

[ -f "$enrollment" ] || {
  echo "live-tailnet enrollment payload is missing" >&2
  exit 1
}

[ -f "$ssh_key" ] || {
  echo "Nerves SSH private key is missing: $ssh_key" >&2
  exit 1
}

mkdir -p "$work"
rm -f "$disk" "$console" "$log" "$qemu_log"

plc_netdev="user,id=plc,net=192.168.10.0/24,restrict=on,guestfwd=tcp:192.168.10.100:10102-cmd:/bin/cat"

if [ "${PLC_REMOTE_TAILNET_SKIP_BUILD:-0}" != "1" ]; then
  "$root/test/firmware/build.sh" build
fi

"$root/test/firmware/build.sh" inspect
qemu-img create -f raw "$disk" 1G >/dev/null
fwup -a -t complete -d "$disk" -i "$firmware" >/dev/null

start_vm() {
  rm -f "$console"

  qemu-system-x86_64 \
    -drive "file=$disk,if=virtio,format=raw" \
    -netdev "user,id=wan,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
    -device virtio-net-pci,netdev=wan,id=wan0,mac=02:00:00:00:00:10,disable-legacy=on \
    -netdev "$plc_netdev" \
    -device virtio-net-pci,netdev=plc,id=plc0,mac=02:00:00:00:00:20,disable-legacy=on \
    -display none \
    -monitor none \
    -accel "$qemu_accelerator" \
    -chardev "socket,id=console,path=$console,server=on,wait=on" \
    -serial chardev:console \
    -m 1024 \
    >>"$qemu_log" 2>&1 &
  pid=$!
}

stop_vm() {
  if [ -n "$pid" ]; then
    for _attempt in $(seq 1 300); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done

    if kill -0 "$pid" 2>/dev/null; then
      echo "QEMU did not stop after guest poweroff" >&2
      exit 1
    fi

    wait "$pid" 2>/dev/null || true
    pid=""
  fi

}

ssh_exec() {
  timeout 240 ssh \
    -p "$ssh_port" \
    -i "$ssh_key" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    nerves@127.0.0.1 "$1"
}

await_ssh() {
  for _attempt in $(seq 1 120); do
    if ssh_exec 'IO.puts(PlcRemote.Integration.result(:ssh_ready))' 2>/dev/null | grep -q 'PLC_REMOTE_CI::ssh_ready'; then
      return 0
    fi
    sleep 0.5
  done

  echo "Nerves SSH did not become ready" >&2
  exit 1
}

start_vm

provisioned="$(elixir "$root/test/support/qemu_cli.exs" console "$console" "$log" \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.provision_ethernet_roles(10102)))' \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_connection(:internet)))')"
printf '%s\n' "$provisioned"
printf '%s\n' "$provisioned" | grep -q 'connection: :internet'

await_ssh

printf 'put %s %s\n' "$enrollment" "$remote_enrollment" | timeout 30 sftp \
  -P "$ssh_port" \
  -i "$ssh_key" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  nerves@127.0.0.1 >/dev/null

# The auth key is consumed from a volatile SFTP upload. It never appears in an
# SSH command, QEMU argument, firmware image, persistent setting, or harness log.
enrolled="$(ssh_exec 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.enroll_tailnet("/tmp/plc-remote-tailnet-enrollment.json")))')"
printf '%s\n' "$enrolled"
printf '%s\n' "$enrolled" | grep -q 'auth_payload_removed: true'
rm -f "$enrollment"

tailnet="$(ssh_exec 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_tailnet()))')"
printf '%s\n' "$tailnet"
printf '%s\n' "$tailnet" | grep -q 'lifecycle: :connected'
tailnet_ip="$(printf '%s\n' "$tailnet" | sed -n 's/.*tailnet_ipv4: "\([0-9.]*\)".*/\1/p')"

[ -n "$tailnet_ip" ] || {
  echo "Unable to extract the gateway tailnet IPv4" >&2
  exit 1
}

recorded="$(ssh_exec 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.record_tailnet_identity()))')"
printf '%s\n' "$recorded"
printf '%s\n' "$recorded" | grep -q 'identity_recorded: true'

tailscale ping --timeout=30s "$tailnet_ip"
elixir "$root/test/support/tcp_echo_client.exs" "$tailnet_ip" 102

poweroff="$(ssh_exec 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.schedule_poweroff()))')"
printf '%s\n' "$poweroff"
printf '%s\n' "$poweroff" | grep -q 'PLC_REMOTE_CI::ok'
stop_vm

start_vm
booted="$(elixir "$root/test/support/qemu_cli.exs" console "$console" "$log" \
  'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.health()))')"
printf '%s\n' "$booted"
await_ssh

reconnected="$(ssh_exec 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.await_tailnet()))')"
printf '%s\n' "$reconnected"
printf '%s\n' "$reconnected" | grep -q 'lifecycle: :connected'

identity="$(ssh_exec 'IO.puts(PlcRemote.Integration.result(PlcRemote.Integration.verify_tailnet_identity()))')"
printf '%s\n' "$identity"
printf '%s\n' "$identity" | grep -q 'identity_persisted: true'

reconnected_ip="$(printf '%s\n' "$reconnected" | sed -n 's/.*tailnet_ipv4: "\([0-9.]*\)".*/\1/p')"
[ "$reconnected_ip" = "$tailnet_ip" ] || {
  echo "Gateway tailnet IPv4 changed after reboot" >&2
  exit 1
}

elixir "$root/test/support/tcp_echo_client.exs" "$tailnet_ip" 102

echo "Live tailscale-rs enrollment, tailscaled interoperability, PLC proxy, and identity persistence passed"

cleanup
trap - EXIT INT TERM
exit 0
