#!/bin/sh
set -eu

tailscale_dir="deps/tailscale"
source_file="$tailscale_dir/ts_runtime/src/netmon.rs"
patch_file="patches/tailscale-rs-netmon-shutdown.patch"
marker="ignored netmon update after runtime shutdown"

if [ ! -f "$source_file" ]; then
  if [ "${MIX_TARGET:-host}" = "host" ]; then
    exit 0
  fi

  echo "tailscale-rs source is missing; run mix deps.get first" >&2
  exit 1
fi

if grep -q "$marker" "$source_file"; then
  exit 0
fi

if ! git -C "$tailscale_dir" apply --check "../../$patch_file"; then
  echo "tailscale-rs no longer matches $patch_file" >&2
  exit 1
fi

git -C "$tailscale_dir" apply "../../$patch_file"
touch "$tailscale_dir/ts_elixir/mix.exs"
