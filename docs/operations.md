# PLC Remote field operations

## Cabling

PLC Remote requires two distinct Ethernet interfaces:

1. **Internet** — connect to the site router, normally using DHCP.
2. **PLC LAN** — connect directly to the PLC network after separate provisioning.

Do not connect the service Wi-Fi to the Internet. It is an AP-only local
maintenance interface.

## First boot

1. Power the gateway with the Internet Ethernet cable connected.
2. Join `PLC-Remote-<serial>`.
3. Open `http://plc.setup/`.
4. Select the detected Ethernet port whose link leads to the router.
5. Save and wait for **Internet connection works**.
6. Paste a short-lived Tailscale auth key and wait for the tailnet address.
7. Select **Finish setup**.

Final verification occurs while the AP stays active. Success persists the
commissioning marker and closes the AP. Failure leaves it active. PLC addressing
and the PLC-side Ethernet path are not part of this wizard.

A first formatted boot may emit one `erlang-shell-log.siz` `:enoent` warning
before Nerves mounts `/root`; it should not recur.

## Health checks

From trusted local UART/USB IEx:

```elixir
PlcRemote.NetworkManager.status()
PlcRemote.TailscaleManager.status()
PlcRemote.RecoveryManager.status()
PlcRemote.FirmwareValidator.status()
RingLogger.grep(~r/network|tailscale|recovery|firmware/i)
```

Expected normal roles after full provisioning resemble:

```elixir
%{
  internet_uplink: "eth1",
  machine_lan: "eth0",
  service_ap: "wlan0",
  recovery: "usb0"
}
```

The names may differ; the persisted hardware paths determine identity.

## PLC provisioning check

Before enabling the proxy, verify:

- Internet and PLC paths are distinct;
- the gateway PLC address and PLC target share a subnet;
- the PLC subnet does not overlap Internet or `192.168.50.0/24`;
- the PLC role has no gateway or DNS;
- Tailscale status remains connected after applying the PLC role.

Then test:

```text
technician Tailscale client
  -> <gateway tailnet IPv4>:102
  -> configured PLC IPv4:102
```

No subnet route is expected or required.

## Recovery ladder

For a commissioned gateway with Tailscale enabled:

| Approximate time | Action |
| --- | --- |
| Internal | Jittered Tailscale retry, capped at five minutes |
| 2 minutes | Immediate Tailscale reconnect |
| 5 minutes | Reapply disable-first Ethernet roles |
| 15 minutes | Cycle the Internet Ethernet role |
| 30 minutes | Restart Tailscale manager and all tasks |
| 60 minutes | Persist budget and reboot |

At most two consecutive automatic recovery reboots occur by default. The budget
resets after ten minutes of stable Tailscale access:

```elixir
PlcRemote.RecoveryManager.reset_reboot_budget()
```

Automatic reboot is suppressed while uncommissioned, in service mode, with
Tailscale disabled, for unvalidated firmware, after budget exhaustion, or when
the updated budget cannot be persisted.

## GPIO service mode

After commissioning, hold the configured physical input to start the bounded
WPA2 service AP. Onsite edits are transactional. They commit only after final
Ethernet and Tailscale verification. Exit, timeout, failure, process restart, or
power loss restores the previous snapshot.

Delete settings only as an intentional factory-reset operation; the next boot
returns to the open first-boot AP.

## OTA update procedure

1. Confirm current status:

   ```elixir
   Nerves.Runtime.firmware_validation_status()
   PlcRemote.TailscaleManager.status()
   ```

2. Record proven remote access:

   ```elixir
   :ok = PlcRemote.FirmwareValidator.prepare_for_update()
   ```

3. Apply a signed fwup image over signature-enforcing transport.
4. Allow the alternate slot to boot.
5. Monitor `PlcRemote.FirmwareValidator.status/0`.
6. Do not install another candidate until it is validated.

A commissioned candidate must hold Tailscale for one minute. If Internet works
but Tailscale cannot recover for 45 minutes, the candidate reverts. Persisted
pre-update evidence also permits reversion when the candidate loses all
Internet. Without that evidence, an external Internet outage leaves the image
running but unvalidated rather than causing a slot-flipping loop.

Manual local escape hatches:

```elixir
Nerves.Runtime.firmware_validation_status()
Nerves.Runtime.validate_firmware()
Nerves.Runtime.revert()
```

## Settings compatibility

Schema v4 removes Wi-Fi WAN behavior. Stored Ethernet/automatic configurations
with an assigned Ethernet path migrate to Ethernet-only mode. A Wi-Fi-only
commissioned configuration becomes uncommissioned and starts the setup AP so an
operator can select an Ethernet Internet path.

Keep future migrations readable by the previous A/B slot until candidate
validation, or add an explicit versioned backup/restore protocol.

## QEMU firmware validation

Install QEMU x86_64, `qemu-img`, Python 3, and `fwup`, then add both Rust targets:

```sh
rustup target add aarch64-unknown-linux-gnu x86_64-unknown-linux-musl --toolchain 1.95.0
mix ci.x86
mix ci.qemu
mix ci.integration
```

The project-wide `mix ci` runs this integration lane after the host quality
gates. `mix ci.x86` builds the x86_64 Nerves firmware and inspects the packaged
`ts_elixir.so`. `mix ci.qemu` creates and flashes a disposable disk, boots with
one QEMU Internet NIC and one isolated PLC NIC, and checks:

- Nerves, BEAM, and the PLC Remote supervision tree start;
- both virtio Ethernet interfaces are detected by fixed MAC and hardware path;
- the WAN receives QEMU DHCP Internet while the PLC side remains isolated;
- settings and distinct Ethernet roles apply through real VintageNet;
- `Tailscale.Native.load_key_file/1` executes successfully inside Nerves;
- QMP can drop and restore the PLC link.

Artifacts and serial logs are left in `_build/qemu_integration` on failure.
These tests use no Tailscale secret. GitHub Actions runs the same lane with
QEMU TCG on pushes and pull requests, uploads emulator logs even after failure,
and retains successful x86 firmware temporarily. `mix ci.integration` builds
once and then runs QEMU with the optional isolated, interface-bound TCP echo at
`192.168.10.100:10102` through a restricted QEMU user network. Real enrollment, identity reuse, live
tailnet proxy traffic, and S7 simulation belong in subsequent protected CI
stages.
