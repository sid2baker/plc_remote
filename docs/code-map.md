# PLC Remote code map

## Configuration

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Settings` | Defaults, v4 migration, parameter normalization, complete validation |
| `PlcRemote.Settings.Store` | Atomic owner-only JSON storage |
| `PlcRemote.Configuration` | Settings ownership, publication, and onsite rollback transaction |
| `PlcRemote.Commissioning` | Pure Ethernet/Tailscale final-check rules |

Only `Configuration` persists the commissioned marker. Tailscale auth keys are
returned separately from settings and remain transient.

## Networking

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Network` | Pure Ethernet role resolution plus PLC/service configurations |
| `PlcRemote.NetworkManager` | Disable-first Ethernet application and hardware refresh |
| `PlcRemote.Adapters.Network` | Application/target networking contract |
| `PlcRemote.Adapters.Target.Network` | Serialized VintageNet configuration and diagnostics |
| `PlcRemote.Adapters.Host.Network` | Deterministic host hardware model |
| `PlcRemote.Integration` | x86-only serial test commands for real Nerves/QEMU boundaries |
| `integration/qemu/run.sh` | fwup disk, QEMU topology, console assertions, and QMP link control |

Wi-Fi AP configuration is built by `Network` and invoked only through
`ServiceMode.Platform`. No application module scans or configures Wi-Fi station
mode.

## Tailscale and proxy

| Module | Responsibility |
| --- | --- |
| `PlcRemote.TailscaleSupervisor` | One lifetime for manager, connection tasks, and sessions |
| `PlcRemote.TailscaleManager` | Enrollment, retry state, optional fixed listener, session ownership |
| `PlcRemote.Adapters.Target.Tailscale` | Only direct `tailscale-rs` integration |
| `PlcRemote.TcpProxy` | Bidirectional bytes between one tailnet stream and fixed PLC socket |

No component installs a subnet route or accepts a destination from a remote
peer.

## Service and web

| Module | Responsibility |
| --- | --- |
| `PlcRemote.ServiceMode.Supervisor` | One-for-all Phoenix, Bandit, and AP state boundary |
| `PlcRemote.ServiceMode` | First setup, GPIO recovery, final verification, transactional exit |
| `PlcRemote.ServiceMode.Platform` | GPIO, AP, serial number, and bind-address facade |
| `PlcRemote.ServiceMode.WebRuntimeSupervisor` | Per-device endpoint secret and Phoenix runtime |
| `PlcRemote.ServiceMode.WebSupervisor` | Temporary Bandit listener |
| `PlcRemoteWeb.CommissioningLive` | Ethernet → Tailscale → Verify UI |
| `PlcRemoteWeb.Router` | LiveView and captive-probe routes |
| `PlcRemoteWeb.Endpoint` | Sessions, transports, static assets, HTTP boundary |
| `Volt` | Host-only TypeScript/CSS build |

Final checks run while the AP is still active. Success closes it; failure leaves
it active. Protected onsite settings commit only after the same checks pass.

## Recovery and firmware

| Module | Responsibility |
| --- | --- |
| `PlcRemote.RecoveryManager` | Reconnect, Ethernet reapply/cycle, Tailscale restart, bounded reboot |
| `PlcRemote.Recovery.Policy` | Pure escalation ordering |
| `PlcRemote.Recovery.Safety` | Reboot budget and candidate-firmware guards |
| `PlcRemote.Recovery.Store` | Persistent reboot budget |
| `PlcRemote.FirmwareValidator` | Evidence-based tentative firmware validation/rollback |
| `PlcRemote.Adapters.System` | Heart, A/B validation, rollback, and reboot boundary |

## Invariants

1. Disable every detected Ethernet interface before applying active roles.
2. Identify Ethernet roles by hardware path, never `ethN`.
3. Internet is Ethernet-only; `wlan0` is AP-only.
4. Never give the PLC interface a gateway or DNS.
5. Never bridge, NAT, route the PLC subnet, or enable kernel forwarding.
6. Never persist or render a Tailscale auth key.
7. Open no PLC listener while the PLC role is disabled.
8. Keep manager-owned tasks/listeners in one supervision lifetime.
9. Keep the first-boot AP until explicit verification succeeds.
10. Keep onsite changes behind a power-loss-safe rollback snapshot.
11. Never automatically reboot an unvalidated candidate.
12. Keep A/B settings compatibility until candidate validation.

## Validation

```sh
mix ci
mix ci.x86
mix ci.qemu
mix ci.integration
MIX_TARGET=rpi4 mix compile --force --warnings-as-errors
MIX_TARGET=rpi5 mix compile --force --warnings-as-errors
```

Hardware-affecting changes additionally require repeated UART-observed boots,
Ethernet path confirmation, setup/GPIO AP checks, tailnet enrollment, and a real
PLC proxy test.
