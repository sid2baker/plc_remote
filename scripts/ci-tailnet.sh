#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
work="${PLC_REMOTE_TAILNET_WORKDIR:-$root/_build/qemu_tailnet}"
payload="$work/enrollment.json"
state="$work/tailnet-api-state.json"
hostname="${PLC_REMOTE_TAILNET_HOSTNAME:-plc-remote-ci-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
tags="${PLC_REMOTE_TAILNET_TAGS:?set PLC_REMOTE_TAILNET_TAGS}"
cleanup_enabled=0

cleanup() {
  if [ "$cleanup_enabled" = "1" ] && [ -n "${TS_OAUTH_CLIENT_ID:-}" ] && [ -n "${TS_OAUTH_SECRET:-}" ]; then
    python3 "$root/integration/qemu/tailnet_api.py" cleanup \
      --hostname "$hostname" \
      --payload "$payload" \
      --state "$state" || true
  fi

  rm -f "$payload"
  return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$work"
chmod 700 "$work"

python3 "$root/integration/qemu/tailnet_api.py" issue \
  --hostname "$hostname" \
  --tags "$tags" \
  --payload "$payload" \
  --state "$state"
cleanup_enabled=1

PLC_REMOTE_TAILNET_ENROLLMENT_FILE="$payload" \
  "$root/integration/qemu/run-tailnet.sh"
