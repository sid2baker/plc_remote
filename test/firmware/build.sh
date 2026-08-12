#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "$root"

mode="${1:-build}"
export MIX_TARGET=x86_64

case "$mode" in
  build)
    mix deps.get
    mix compile --force --warnings-as-errors
    mix firmware
    ;;
  inspect)
    nif="$(find _build/x86_64_dev -path '*/priv/native/ts_elixir.so' -print -quit)"

    if [ -z "$nif" ]; then
      echo "tailscale-rs NIF was not packaged" >&2
      exit 1
    fi

    file "$nif"
    file "$nif" | grep -q 'ELF 64-bit.*x86-64'
    readelf -h "$nif" | grep -q 'Machine:.*Advanced Micro Devices X86-64'
    readelf -d "$nif" | grep -q 'Shared library: \[libc.so\]'
    ;;
  *)
    echo "usage: $0 {build|inspect}" >&2
    exit 2
    ;;
esac
