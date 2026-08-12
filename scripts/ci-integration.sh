#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

"$root/scripts/ci-x86.sh" build
PLC_REMOTE_QEMU_SKIP_BUILD=1 PLC_REMOTE_QEMU_PLC_FIXTURE=1 \
  "$root/integration/qemu/run.sh"
