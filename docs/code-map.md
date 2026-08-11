# PLC Remote code map

This document answers “where should this change go?” without requiring a reader
to reconstruct the OTP tree first.

## Configuration boundary

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Settings` | Pure defaults, form normalization, migration, and complete validation |
| `PlcRemote.Settings.Store` | Owner-only atomic JSON file operations |
| `PlcRemote.Configuration` | The only process allowed to own, persist, and publish settings |
| `PlcRemote.Commissioning` | Pure rules deciding whether first-boot setup is required and safe to complete |

Authentication keys are transient values returned separately from settings.
Only `Configuration` may set the persisted `commissioned` marker.

## Network boundary

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Network` | Pure VintageNet configuration builders and hardware-path role resolution |
| `PlcRemote.NetworkManager` | Disable-first application of network intent and hardware refresh |
| `PlcRemote.Adapters.Network` | Contract between application logic and a networking implementation |
| `PlcRemote.Adapters.Target.Network` | Serialized VintageNet calls, bounded transition waits, and target diagnostics |
| `PlcRemote.Adapters.Host.Network` | Deterministic development hardware model |
| `PlcRemote.RecoveryManager` | Bounded reconnect, network-cycle, supervisor-restart, and reboot escalation |
| `PlcRemote.Recovery.Policy` | Pure least-disruptive escalation ordering |
| `PlcRemote.Recovery.Safety` | Pure reboot budget and firmware escape-hatch checks |
| `PlcRemote.Recovery.Store` | Independent owner-only persistent reboot budget |

Do not call VintageNet from application modules. The target adapter serializes
calls because VintageNet cannot accept a new configuration while an interface is
in its `:reconfiguring` state.

## Tailscale boundary

| Module | Responsibility |
| --- | --- |
| `PlcRemote.TailscaleSupervisor` | One lifetime for manager, connection tasks, and sessions |
| `PlcRemote.TailscaleManager` | Enrollment, reconnect policy, listener ownership, and commissioning completion |
| `PlcRemote.Adapters.Tailscale` | Small transport contract used by the manager and proxy |
| `PlcRemote.Adapters.Target.Tailscale` | The only direct `tailscale-rs` integration |
| `PlcRemote.TcpProxy` | Bidirectional copying between one tailnet stream and one fixed PLC socket |

The manager never installs a subnet route. A remote peer cannot choose the PLC
address or destination port through the data stream.

## Commissioning boundary

| Module | Responsibility |
| --- | --- |
| `PlcRemote.ServiceMode.Supervisor` | Shared failure boundary for service state and Bandit |
| `PlcRemote.ServiceMode` | Automatic/open and GPIO/WPA2 lifecycle state machine |
| `PlcRemote.ServiceMode.Platform` | GPIO, AP, device identity, and bind-address facade |
| `PlcRemote.ServiceMode.WebSupervisor` | Temporary Bandit child ownership |
| `PlcRemoteWeb.Router` | HTTP, CSRF, captive redirects, and non-secret status API |
| `PlcRemoteWeb.Page` | Server-rendered settings page |
| `PlcRemote.FirmwareValidator` | Product-level tentative firmware validation and A/B rollback |
| `PlcRemote.Adapters.System` | Testable boundary for Heart, validation, rollback, and reboot |

First boot stays open until a real tailnet connection and safe network roles are
persisted. Later recovery requires GPIO activation and uses WPA2.

## Non-negotiable invariants

1. Disable every detected Ethernet interface before applying role assignments.
2. Identify Ethernet roles by hardware path, never by `ethN` name.
3. Never add a gateway or DNS server to the machine interface.
4. Never enable bridging, NAT, IPv4 forwarding, or IPv6 forwarding.
5. Never persist or render a Tailscale auth key.
6. Never stop first-boot commissioning merely because settings were submitted.
7. Never let a manager restart leave its listeners, sessions, or web server alive.
8. Keep target-only libraries behind adapters in `target/`; keep host fakes in `host/`.
9. Never automatically reboot an unvalidated candidate firmware.
10. Never reset the recovery reboot budget until Tailscale remains stable.
11. Keep post-v2 settings migrations additive until the candidate image is validated.

## Validation path

For every change:

```sh
mix format
mix test
mix credo --strict
mix dialyzer
mix ci
MIX_TARGET=rpi4 mix compile --warnings-as-errors
MIX_TARGET=rpi5 mix compile --warnings-as-errors
```

Hardware-affecting changes additionally require UART logs and a real AP, role,
Tailscale, and PLC connection check before deployment.
