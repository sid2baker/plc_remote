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
WAN DHCP Internet, dual Ethernet isolation, observed QMP link cycling, invalid
auth-key fail-closed behavior, and native execution of
`Tailscale.Native.load_key_file/1` under Nerves musl. It consumes no Tailscale
credential.

An optional unprivileged fixture uses a separate, restricted QEMU user network
and `guestfwd` to verify a `SO_BINDTODEVICE` TCP echo from the firmware:

```sh
mix ci.integration
```

The fixture is visible to the PLC NIC as `192.168.10.100:10102`, has no route to
the WAN, and forwards only that TCP endpoint to a loopback host process. GitHub
Actions runs this fixture-enabled lane without secrets and retains the QEMU logs
for diagnosis.

## Protected live-tailnet lane

`mix ci.tailnet` is intentionally not part of `mix ci`. It requires:

- `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` with `auth_keys` scope;
- `PLC_REMOTE_TAILNET_TAGS`, such as `tag:plc-remote-ci`;
- a mature `tailscaled` peer in the same restricted tailnet;
- tailnet policy permitting that peer to reach the gateway tag on TCP/102.

The harness requests a one-use, 15-minute, ephemeral auth key. Its payload is
written mode `0600`, uploaded over SFTP to guest `/tmp`, consumed and deleted
before enrollment, and removed from the host immediately. It never appears in
firmware, QEMU arguments, SSH commands, persistent settings, or logs.

The protected lane verifies invalid-key fail-closed behavior, live
`tailscale-rs` enrollment, DERP interoperability with `tailscaled`, bidirectional
TCP proxy traffic to the isolated PLC fixture, and reuse of the same tailnet
identity and address after a clean reboot. The API key is revoked in teardown;
the ephemeral gateway identity expires automatically. An S7 protocol fixture
remains future work.
