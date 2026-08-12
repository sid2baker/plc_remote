# PLC Remote architecture

## Product boundary

PLC Remote is a purpose-built userspace TCP gateway, not a router.

| Zone | Interface | Default | Purpose |
| --- | --- | --- | --- |
| PLC LAN | Selected Ethernet hardware path | Disabled | Static isolated PLC network |
| Internet | Different selected Ethernet path | Disabled | Site router and Tailscale |
| Service | `wlan0` AP | First boot only | Setup; WPA2 GPIO recovery later |
| Local recovery | `usb0` | On | Nerves IEx and firmware access |

Wi-Fi is never an Internet uplink. There is no station configuration, network
scan, AP/station transition, fallback route, bridge, NAT, subnet route, or
kernel forwarding.

## Remote data path

```text
Authorized tailnet client
  -> gateway tailnet IPv4 + fixed TCP listen port
  -> tailscale-rs userspace listener
  -> PlcRemote.Proxy.TcpProxy
  -> one configured PLC IPv4 + fixed destination port
```

Commissioning may enroll Tailscale before PLC provisioning. While
`machine.enabled` is false, `tailscale-rs` joins but creates no TCP listener.
When provisioned, the remote peer cannot choose another PLC address or port.
Broadcast discovery and Layer 2 protocols do not cross this path.

The pinned `sid2baker/s7` package is independent of the proxy and remains
available from local IEx.

## Ethernet ownership

`PlcRemote.Configuration` persists stable `/devices/...` paths. VintageNet's
ifname-keyed persistence is disabled. `PlcRemote.Network.Runtime` owns Ethernet
configuration and always:

1. Detects physical Ethernet interfaces.
2. Disables every detected Ethernet interface.
3. Resolves the configured Internet and PLC hardware paths.
4. Rejects missing or duplicate active roles.
5. Applies only the valid role configurations.

The PLC role has a static address and prefix without gateway or DNS. The
Internet role uses DHCP or explicit static address, gateway, and DNS. Boot
sysctls disable IPv4/IPv6 forwarding, redirects, and source routing.

## Service AP and commissioning

An uncommissioned target starts an open, non-persistent AP on `wlan0` at
`192.168.50.1/24`. It serves DHCP, wildcard captive DNS for `plc.setup`, and a
temporary Bandit listener. No Wi-Fi scan or station process is involved.

The LiveView wizard has three steps:

1. Select and test the Ethernet Internet port.
2. Enroll the gateway in Tailscale.
3. Verify Ethernet Internet and Tailscale, then close the setup AP.

Final verification runs while the AP remains active. Success atomically marks
the unit commissioned and then closes Bandit and the AP. Failure leaves the AP
active. A reboot before success starts first-boot setup again.

After commissioning, a physical GPIO hold starts a WPA2-protected AP with a
bounded inactivity timeout. Onsite setting updates are transactional. The prior
settings snapshot is restored on explicit exit, timeout, failed verification,
portal crash, service process restart, or power loss unless final verification
commits it.

Phoenix uses CSRF protection, per-device signing material, strict security
headers, no-store responses, no external assets, and no service worker. The
first AP and HTTP portal are intentionally unencrypted, so first commissioning
requires a physically controlled area and a short-lived Tailscale auth key.

## tailscale-rs boundary

The project intentionally pins experimental `tailscale-rs` v0.4.0. The required
`TS_RS_EXPERIMENT=this_is_unstable_software` acknowledgement is installed in
`vm.args` before native code loads. Identity state is owner-only under
`/data/plc_remote/tailscale`.

`PlcRemote.Tailscale.FSM` owns connection lifecycle. `Tailscale.Runtime`
translates typed Network/configuration facts, task results, and timers into FSM
events; `Tailscale.Actions` owns native connection and fixed listener effects. A
one-for-all supervisor tears down runtime, FSM, connection tasks, and proxy
sessions together.
A reproducible dependency patch replaces a reproduced late-netmon `.unwrap()`
panic during runtime shutdown with a non-fatal debug event.

## Recovery and OTA

A commissioned Tailscale outage escalates through:

1. Tailscale reconnect.
2. Disable-first Ethernet role reapply.
3. Internet Ethernet cycle.
4. Complete Tailscale boundary restart.
5. Persisted, budget-limited device reboot.

Reboots are suppressed during setup/service mode and for unvalidated candidate
firmware. The budget resets only after stable Tailscale operation.

`PlcRemote.Firmware` validates uncommissioned candidates after the
setup AP is healthy and commissioned candidates after stable tailnet access.
Pre-update connectivity evidence permits rollback when a candidate loses remote
access; an ordinary external outage is not automatically blamed on firmware.

## Supervision

```text
PlcRemote.Supervisor (:rest_for_one)
├── Configuration
├── Phoenix.PubSub / typed Events
├── Health.Reporter / Alarmist read model
├── Network.Runtime
├── Tailscale.Supervisor (:one_for_all)
│   ├── connection Task.Supervisor
│   ├── session Task.Supervisor
│   └── Tailscale.Runtime + linked FSM
├── Service.Supervisor (:one_for_all)
│   ├── Phoenix runtime (listener disabled)
│   ├── temporary Bandit supervisor
│   └── Service.Runtime + linked FSM
├── Recovery.Runtime + linked FSM
└── Firmware.Runtime + linked FSM
```

Configuration loss restarts every consumer; network loss restarts remote and
service boundaries. Domain effects and their FSM lifecycles therefore cannot
remain orphaned after runtime failure. `PlcRemote.Health` answers current
conditions; typed subsystem statuses answer current activity.

## Hardware validation

The custom CM5 system enables common Realtek RTL815x and ASIX AX88179 USB
Ethernet drivers. Production qualification must verify:

- both physical Ethernet hardware paths and driver identity;
- which connector is the site Internet port and which is the PLC port;
- path stability across repeated boots;
- DI1 GPIO identity and polarity;
- fixed proxy behavior against a real PLC;
- signed A/B OTA transport and rollback.

A CM4 exposing only one Ethernet interface cannot satisfy the isolated two-port
architecture without a second controller.

## x86_64 QEMU integration boundary

`MIX_TARGET=x86_64` packages the same target networking, settings, supervision,
and `tailscale-rs` adapters into `nerves_system_x86_64`. Only GPIO and automatic
Wi-Fi commissioning are replaced: stock QEMU has neither a service WLAN nor a
physical GPIO. Integration-only modules are compiled from `integration/firmware`
and are excluded from CM4/CM5 releases.

The deterministic emulator topology is:

```text
QEMU Nerves firmware
├── virtio WAN (fixed MAC and PCI path) -> QEMU user-mode Internet
└── virtio PLC (different fixed MAC/path) -> isolated/restricted QEMU network
```

The harness flashes a real fwup disk, boots Nerves over a Unix serial socket,
provisions roles by MAC-discovered hardware paths, and controls link state via
QMP. It invokes `Tailscale.Native.load_key_file/1`, not merely application
startup, to prove that the cross-compiled Rustler NIF loads under Nerves musl.
The x86 build disables Rust's static musl CRT for the shared NIF and forces
AWS-LC C objects to be position-independent.

This lane validates firmware packaging, VintageNet, `/data` persistence, stable
role resolution, supervision, and native loading.

The protected live-tailnet variant transfers a one-use credential over SFTP to
guest `/tmp`; firmware reads and deletes it, persists non-secret configuration,
and sends a separate redacted enrollment command. Enrollment therefore
exercises the real FSM/action/adapter boundary without exposing the key through
serial history, SSH commands, persistent settings, firmware artifacts, or
process arguments. A mature
`tailscaled` CI peer tests the deployed TCP direction through the fixed PLC
proxy. Physical CM4/CM5 tests remain authoritative for carrier drivers, Wi-Fi
AP, GPIO, and electrical power-loss behavior.
