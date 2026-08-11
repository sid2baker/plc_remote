# PLC Remote architecture

## Trust zones

| Zone | IPCBOX-CM5-A interface | Default state | Purpose |
| --- | --- | --- | --- |
| Machine LAN | Selected native 1000M hardware path | Disabled until assigned | PLC devices only |
| Wired uplink | Selected USB 2500M hardware path | Disabled until assigned | Preferred Internet path |
| Wi-Fi uplink | `wlan0` | Disabled/scan-only | Optional Internet fallback |
| Service network | `wlan0` AP | Open until enrolled | First-boot commissioning; WPA2 after GPIO recovery |
| Recovery | `usb0` | On | Local Nerves IEx and recovery |

The machine interface receives a static address without a gateway or DNS. The
firmware does not bridge interfaces or enable NAT. Boot sysctls explicitly keep
IPv4/IPv6 forwarding off and reject route redirects/source routing. PLC packets
cannot use the gateway as an Internet router.

## Remote data path

```text
Tailnet operator
  -> gateway tailnet IPv4 + allowlisted TCP port
  -> tailscale-rs userspace listener
  -> fixed PlcRemote.TcpProxy destination
  -> PLC IPv4 + configured TCP port on the selected machine interface
```

The initial mapping defaults to Tailscale TCP/102 -> PLC TCP/102. Tailnet ACLs
remain the first authorization layer; the local fixed destination is the second.
The remote peer cannot select a different LAN address or port through the data
stream.

This is not transparent routing. A technician configures the engineering client
with the gateway's tailnet IPv4, not the PLC IPv4. Broadcast discovery,
PROFINET/DCP, and other Layer 2 traffic are unavailable. Supporting multiple
PLCs requires additional explicit mappings rather than opening the subnet.

The remote data path is a raw TCP relay, so it preserves S7 traffic without
protocol translation. The pinned `sid2baker/s7` library is still included in the
firmware for dynamic PLC diagnostics and configuration from the Nerves IEx
shell; it is intentionally not coupled to proxy availability.

## tailscale-rs boundary

The project intentionally uses `tailscale-rs` 0.4.0. Upstream marks this release
as unstable, unaudited, and DERP-only and explicitly does not support subnet
routers. The target adapter sets the required
`TS_RS_EXPERIMENT=this_is_unstable_software` acknowledgement.

Tailscale key state is stored under `/data/plc_remote/tailscale` with owner-only
permissions. A submitted auth key exists only in the portal request and
connection-manager memory; it is not inserted into persistent settings.

## Internet failover

Normal field configuration uses uplink mode `:auto`. VintageNet configures both
the selected Ethernet uplink and the saved Wi-Fi station network. Its route
policy prefers an Internet-capable Ethernet route, then an Internet-capable
Wi-Fi route. Therefore an Ethernet carrier or upstream Internet failure moves
new Tailscale traffic to Wi-Fi without changing the PLC-side interface.

Tailscale reconnect delay starts at roughly five seconds, grows through 15, 30,
60, and 120 seconds, and caps at five minutes with ±20 percent jitter. Jitter
prevents a fleet from reconnecting simultaneously after a site or control-plane
outage. Entering physical service mode temporarily consumes the single Wi-Fi
radio; Ethernet remains available during that maintenance window.

## Commissioning and service-mode boundary

An uncommissioned target automatically replaces Wi-Fi station mode with an open,
non-persistent setup AP. It assigns `192.168.50.1/24`, starts DHCP and wildcard
DNS for `plc.setup`, and binds Bandit only to that address. The AP has no timeout
while enrollment is incomplete, so a failed network or Tailscale setup cannot
strand a field installer.

A successful `tailscale-rs` connection is not enough by itself. The machine role
must resolve, the selected uplink role must resolve, network application must be
error-free, and the commissioned marker must be atomically persisted. Only then
does the open AP stop. It does not automatically return after commissioning.

The Waveshare IPCBOX-CM5-A exposes DI1 as GPIO23. Its isolated input inverts the
signal, so an asserted external high level is read as CPU level 0. The CM5
device tree names this line `GPIO23` for Circuits.GPIO. After commissioning, a
configured GPIO hold starts the same portal on a WPA2-protected AP. Recovery
stops after explicit exit or the inactivity timeout and restores Wi-Fi WAN.

The settings page has CSRF protection, a strict Content Security Policy,
no-store responses, and no external resources. The captive portal is HTTP to
avoid certificate warnings, so browsers do not activate service workers there.
If HTTPS is added later, the included service worker caches only CSS,
JavaScript, and the manifest; it never caches HTML, API responses, settings, or
credentials.

The initial AP is intentionally passwordless. Commissioning must therefore be
performed in a physically controlled area and the Tailscale auth key should be
short-lived and single-use. A random WPA2 password is generated and persisted
for later GPIO recovery. Manufacturing may retrieve it over USB and place it on
the device label or replace it with another unique credential.

## Settings application

`PlcRemote.Configuration` is the sole settings owner. Updates are validated as a
complete unit, written atomically with mode `0600`, and then sent to the network,
Tailscale, and service-mode managers. Invalid settings are never applied.
Corrupt files are quarantined and replaced with fail-closed defaults.

Ethernet roles persist VintageNet hardware paths rather than kernel interface
names. VintageNet's own ifname-keyed persistence is disabled, preventing stale
`ethN` configurations from activating on a different physical port before the
application starts. On boot and whenever hardware identity changes, the network manager
first disables every detected Ethernet interface. It then resolves the two
configured paths, rejects missing or duplicate active roles, and applies the
machine and uplink configurations. Interface discovery is repeated so a USB
Ethernet controller that initializes late remains fail closed and can be
configured without rebooting.

Application code uses adapter behaviours. Hardware implementations are compiled
from `target/` and selected in `config/target.exs`; host development fakes are
compiled from `host/`. There are no host/target branches inside the runtime
modules.

Settings migrations are additive after schema version 2. A newer image must not
destructively rewrite settings needed by the previous slot before validation.
This keeps rollback viable without onsite reconfiguration.

## Recovery escalation

A commissioned device with enabled Tailscale uses the following least-disruptive
ladder. Thresholds scale with the configured final reboot timeout:

1. Request an immediate Tailscale reconnect.
2. Reapply the disable-first hardware-path network plan.
3. Cycle only Internet uplinks, then reapply the plan.
4. Restart the complete Tailscale supervisor boundary.
5. Persist and perform a full device reboot.

The final reboot defaults to 60 minutes and is limited to two consecutive
recovery reboots. The persistent counter resets only after ten minutes of stable
Tailscale connectivity. A write failure cancels the reboot rather than risking
an unbounded loop. Automatic reboot is suppressed while uncommissioned, while
service mode is active, when Tailscale is intentionally disabled, or while the
running firmware remains unvalidated. Operators can disable reboot recovery,
set its timeout/budget, or reset the budget from local IEx.

An external outage may consequently cause at most the configured number of
reboots. Once the budget is exhausted, the device remains up, keeps using
bounded reconnect attempts, and preserves UART/GPIO diagnostics.

## OTA validation and rollback

The generic Nerves startup guard is intentionally replaced by
`PlcRemote.FirmwareValidator`. The custom validator still completes the Nerves
Heart startup handshake, but it does not declare a candidate image healthy just
because OTP applications started.

- An uncommissioned image validates after its automatic setup AP is healthy.
- A commissioned candidate validates after Tailscale remains connected for one
  minute.
- If VintageNet proves ordinary Internet access but Tailscale cannot recover for
  45 minutes, the candidate explicitly reverts to the previous A/B slot.
- The OTA agent calls `FirmwareValidator.prepare_for_update/0` while the old
  image is connected. That persisted evidence also permits rollback if the
  candidate loses all Internet for the same 45-minute window.
- Without pre-update connectivity evidence, an Internet outage is not blamed on
  firmware. The device stays running and unvalidated, does not reboot itself,
  and a later power cycle can still fall back to the previous slot.

Rollback makes sense for a reproducible regression in the candidate image, not
for ISP failure, missing Wi-Fi credentials, an unplugged cable, expired
Tailscale authorization, or a PLC-side problem. Recovery reboot policy never
reboots an unvalidated candidate; firmware validation owns that decision.

## Supervision and failure boundaries

```text
PlcRemote.Supervisor (:rest_for_one)
├── Configuration
├── NetworkManager
├── TailscaleSupervisor (:one_for_all)
│   ├── connection Task.Supervisor
│   ├── proxy-session Task.Supervisor
│   └── TailscaleManager
├── ServiceMode.Supervisor (:one_for_all)
│   ├── WebSupervisor
│   └── ServiceMode
├── RecoveryManager
└── FirmwareValidator
```

The root ordering follows dependencies: losing configuration restarts every
consumer, and losing networking restarts all remote-access and commissioning
processes. Tailscale tasks share one lifetime with their manager, preventing
orphan listeners or PLC sessions. Service mode shares one lifetime with Bandit,
preventing a stale listener from blocking automatic AP recovery. Tests kill the
managers and verify that every process inside each boundary receives a new PID.

## Hardware validation still required

The local CM5 Nerves system enables Realtek RTL8152/8153/8156 and ASIX AX88179
USB Ethernet drivers because the public Waveshare schematic only identifies a
“USB 2.5G ETH Module”. On the first IPCBOX-CM5-A unit:

1. Open **Detected Ethernet diagnostics** in the service portal.
2. Record both hardware paths, driver names, MAC addresses, and USB
   vendor/product IDs.
3. Verify the physical native 1000M port is selected for the machine role and
   the 2500M USB port is selected for the uplink role.
4. Reboot repeatedly and verify each persisted hardware path resolves to the
   same physical connector even if its kernel `ethN` name changes.

Unassigned, missing, and conflicting Ethernet roles remain disabled. Firmware
still must not be released for unattended deployment before the physical port
identity and DI1 polarity have been verified on a production unit.
