# Firmware tests

These tests boot the real x86_64 Nerves firmware in QEMU. They live under
`test/` because they are tests, but they cannot run inside ExUnit: ExUnit runs on
the host while these checks must exercise Linux, VintageNet, persistence, and
the native Tailscale library inside a virtual device.

Run the one public command:

```sh
mix test.firmware
```

`mix ci` runs it automatically.

Requirements are QEMU x86_64, `qemu-img`, `fwup`, Rust 1.95.0 with the
`x86_64-unknown-linux-musl` target, and the Nerves x86_64 system/toolchain.
`PLC_REMOTE_QEMU_ACCELERATOR` defaults to portable TCG; set it to `kvm` only on
a trusted host with KVM available.

The VM has two fixed virtio NICs:

- `02:00:00:00:00:10`: Internet side
- `02:00:00:00:00:20`: isolated PLC side

The test verifies firmware boot, supervision, the real NIF, DHCP Internet,
stable Ethernet-role resolution, an isolated PLC TCP echo, QMP link changes,
graceful shutdown, and `/data` persistence. QEMU runs `/bin/cat` as the tiny PLC
echo endpoint, so no separate fixture program is needed. Its x86 target has no
Wi-Fi device; an integration-only service-AP adapter confirms the lifecycle
request without replacing target Ethernet, VintageNet, routing, or NIF adapters.

The reviewer-protected workflow also runs `mix test.invalid-key`, then
`mix ci.tailnet`. Those tests verify fail-closed enrollment and live
`tailscale-rs` interoperability. They are not run for pull requests or normal
local development.
