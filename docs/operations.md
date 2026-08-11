# PLC Remote field operations

## Recommended uplink configuration

Use **Automatic — Ethernet preferred** and configure both:

1. The selected 2500M Ethernet role, normally with DHCP.
2. A WPA2 Wi-Fi station network with DHCP or a valid static route.

VintageNet keeps both configured. Ethernet wins while it has Internet; Wi-Fi
wins when Ethernet no longer has Internet. Service mode temporarily replaces the
Wi-Fi station because the device has one radio.

## Inspecting health

From local UART/USB IEx:

```elixir
PlcRemote.NetworkManager.status()
PlcRemote.TailscaleManager.status()
PlcRemote.RecoveryManager.status()
PlcRemote.FirmwareValidator.status()
RingLogger.grep(~r/network|tailscale|recovery|firmware/i)
```

The service portal exposes the same non-secret state through `/api/status`.

## Recovery ladder

For a commissioned gateway with Tailscale enabled, the default 60-minute outage
window performs:

| Approximate time | Action |
| --- | --- |
| Internal | Tailscale retries at 5, 15, 30, 60, 120, then ≤300 seconds with jitter |
| 2 minutes | Immediate Tailscale reconnect |
| 5 minutes | Reapply hardware-path network configuration |
| 15 minutes | Disable and cycle Internet uplinks |
| 30 minutes | Restart manager, connection tasks, and sessions together |
| 60 minutes | Persist budget and reboot |

Actions are spaced by at least one minute. The device performs at most the
configured consecutive reboot count, default two. It then stays up for UART,
GPIO, and log diagnostics while continuing bounded Tailscale retries.

The reboot budget resets only after ten minutes of stable Tailscale operation.
A trusted local operator may reset it explicitly:

```elixir
PlcRemote.RecoveryManager.reset_reboot_budget()
```

## Reboot escape hatches

Automatic recovery reboot does not run when:

- the gateway is uncommissioned;
- Tailscale is intentionally disabled;
- automatic reboot is disabled in settings;
- GPIO service mode is active;
- candidate firmware is unvalidated;
- the persistent reboot count reached its budget; or
- the updated budget cannot be written safely.

UART remains the lowest-level access path. GPIO service mode provides a
WPA2-protected local portal after commissioning. Deleting settings as a factory
operation returns the next boot to the open first-boot WLAN.

## OTA update procedure

Only install a candidate while the current image is validated and the gateway
has demonstrated stable remote connectivity.

1. Confirm:

   ```elixir
   Nerves.Runtime.firmware_validation_status()
   PlcRemote.TailscaleManager.status()
   ```

2. Record that the current firmware has a working remote path:

   ```elixir
   :ok = PlcRemote.FirmwareValidator.prepare_for_update()
   ```

   The call fails unless current firmware is validated and Tailscale is
   connected.
3. Apply a signed fwup image with an OTA transport that pins the verification
   public key. Development images in this repository are unsigned until
   deployment signing keys are provisioned.
4. Let the candidate boot into the alternate A/B slot.
5. Monitor `PlcRemote.FirmwareValidator.status/0` through the OTA control plane.
6. Do not install another candidate until status becomes `:validated`.

A commissioned candidate must hold Tailscale for one minute before validation.
If VintageNet proves Internet works but Tailscale remains unavailable for 45
minutes—after all non-reboot recovery stages—the device reverts to its previous
slot. If `prepare_for_update/0` recorded that the previous image was online, the
same deadline also covers a candidate that loses all Internet; this provides
evidence that the candidate caused the regression. Without that evidence, an
Internet outage leaves the candidate running but unvalidated. It is not rebooted
merely to force a rollback; a later external power cycle can still select the
old slot.

## When rollback is appropriate

Rollback is useful when all of the following are true:

- the image is a newly installed, unvalidated candidate;
- the device has ordinary Internet connectivity;
- configured roles and credentials still exist;
- the candidate cannot restore the expected Tailscale control path; and
- bounded reconnect, network reapply, uplink cycle, and Tailscale restart failed.

Rollback is not evidence-based for an ISP outage, unplugged cable, expired auth,
changed access point, or failed PLC. Those conditions survive old firmware and
must not create slot-flipping loops.

## Manual firmware escape hatches

From trusted local IEx:

```elixir
Nerves.Runtime.firmware_validation_status()
Nerves.Runtime.validate_firmware() # accept current candidate deliberately
Nerves.Runtime.revert()            # select previous slot and reboot
```

Manual validation should be exceptional and recorded operationally.

## Persistence compatibility

Do not make destructive settings migrations in an unvalidated image. Schema
changes after version 2 must remain additive so the previous firmware can read
`/data/plc_remote/settings.json` after rollback. Any future incompatible
migration needs a versioned backup plus restore as part of the A/B protocol.
