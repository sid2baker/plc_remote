# PLC Remote QEMU integration

This harness boots the real `MIX_TARGET=x86_64` Nerves firmware. It does not run
the host adapters and it does not install `tailscaled`.

## Requirements

- QEMU x86_64 and `qemu-img`
- Python 3
- `fwup`
- Rust 1.95.0 with `x86_64-unknown-linux-musl`
- the Nerves x86_64 system/toolchain artifacts

Run:

```sh
mix ci.x86
mix ci.qemu
mix ci.integration
```

`PLC_REMOTE_QEMU_ACCELERATOR` defaults to `tcg` for portable and deterministic
execution. Set it to `kvm` only when `/dev/kvm` is available and trusted.

The VM has two virtio NICs with fixed MAC and PCI identities:

- `02:00:00:00:00:10`: QEMU user-mode Internet
- `02:00:00:00:00:20`: isolated/restricted PLC-side QEMU network

The firmware resolves their actual VintageNet hardware paths and never assumes
that they are named `eth0` and `eth1`. The console protocol is available only in
the x86 integration firmware. QMP controls link state without requiring a guest
shell.

The current deterministic gate validates boot, OTP ownership, role settings,
WAN DHCP Internet, dual Ethernet isolation, observed QMP link cycling, and native
execution of `Tailscale.Native.load_key_file/1` under Nerves musl. It consumes no
Tailscale credential.

An optional unprivileged fixture uses a separate, restricted QEMU user network
and `guestfwd` to verify a `SO_BINDTODEVICE` TCP echo from the firmware:

```sh
mix ci.integration
```

The fixture is visible to the PLC NIC as `192.168.10.100:10102`, has no route to
the WAN, and forwards only that TCP endpoint to a loopback host process. GitHub Actions runs this fixture-enabled lane without secrets and retains the
QEMU logs for diagnosis. Future protected stages will add disposable Tailscale
enrollment, identity reuse after reboot, live fixed TCP proxy traffic, and an S7
protocol fixture.
