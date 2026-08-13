# PLC Remote v2 code map

See [`architecture-v2.md`](architecture-v2.md) for the enforceable observation →
alarm → policy/FSM → action → adapter rules.

## Health and events

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Health` | Alarm-backed product health read model |
| `PlcRemote.Health.Reporter` | Configuration/service observations and derived-alarm registration |
| `PlcRemote.Health.Alarm` | Primitive alarm set/clear boundary |
| `PlcRemote.Health.Alarms.*` | Named primitive and derived conditions |
| `PlcRemote.Events` | Typed local fact publication; never commands or credentials |
| `PlcRemote.Diagnostics` | Supported non-secret field snapshot and explanation |
| `PlcRemote.Clock` | Injectable monotonic time and timer boundary |

`RemoteAccessUnavailable` is derived by Alarmist from `RemoteAccessExpected`
and `TailscaleUnavailable`; no subsystem sets it imperatively.

## Configuration

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Settings` | Defaults, v4 migration, normalization, validation, credential extraction |
| `PlcRemote.Settings.Store` | Atomic owner-only JSON storage |
| `PlcRemote.Configuration` | Persistent validated settings ownership and revision publication |
| `PlcRemote.Tailscale.Enrollment` | Redacted, transient one-use credential command value |

`ConfigurationChanged` contains only a revision. Consumers read the new
validated configuration from `Configuration.current/0`. An enrollment key is
never part of persistent settings or an event.

## Network

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Network` | Public runtime API and pure Ethernet/service configurations |
| `PlcRemote.Network.Plan` | Complete disable baseline plus resolved active role plan |
| `PlcRemote.Network.Actions` | Configure ordering with disable-first execution |
| `PlcRemote.Network.Runtime` | Discovery, refresh, plan application, typed status, network alarms |
| `PlcRemote.Network.Status` | Non-secret operational network status |
| `PlcRemote.Adapters.Target.Network` | Serialized VintageNet boundary |

Network owns `NetworkConfigurationInvalid`, `InternetUnavailable`, and
`PlcInterfaceUnavailable`; it never decides product remote-access health.

## Tailscale and proxy

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Tailscale` | Public status, reconnect, and enrollment API |
| `PlcRemote.Tailscale.FSM` | Disabled/waiting/connecting/connected/retry lifecycle |
| `PlcRemote.Tailscale.Runtime` | Typed-event, task-result, and timer translation into FSM events |
| `PlcRemote.Tailscale.Actions` | Native connection, listener accept loop, and session teardown |
| `PlcRemote.Tailscale.Supervisor` | One lifetime for tasks, sessions, runtime, and FSM |
| `PlcRemote.Proxy.Policy` | Pure fixed-listener interface policy |
| `PlcRemote.Proxy.TcpProxy` | Bidirectional bytes to one fixed PLC destination |
| `PlcRemote.Adapters.Target.Tailscale` | Candidate identity validation/promotion and direct `tailscale-rs` integration |

## Service and web

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Service` | Public switch-controlled WLAN status/recheck API |
| `PlcRemote.Service.FSM` | Inactive, active, and fault lifecycle |
| `PlcRemote.Service.Runtime` | Direct debounced IN1 observation and portal lifecycle |
| `PlcRemote.Service.State` | Grouped portal, GPIO, and routing resources |
| `PlcRemote.Service.Actions` | WPA2 AP, web, and routing effects |
| `PlcRemote.Service.Router` | Scoped `wlan0` → WAN forwarding boundary |
| `PlcRemote.Service.GPIO` | GPIO adaptation and primitive GPIO alarm |
| `PlcRemote.Service.Supervisor` | One-for-all Phoenix, Bandit, runtime, and FSM boundary |
| `PlcRemoteWeb.ConfigurationLive` | One live detected-device and configuration page |

## IPCBOX panel

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Panel.Runtime` | Owns IN2, OUT1/OUT2, and USER1/USER2 GPIO resources |
| `PlcRemote.Panel.Policy` | Pure indicator/output levels from typed observations |
| `PlcRemote.Panel.Status` | Non-secret panel and isolated-I/O read model |
| `PlcRemote.Adapters.GPIO` | Input subscription and output write contract |

IN1 remains owned by `Service.Runtime`. Panel outputs initialize to physical off
before observations are applied. IN2 can request only a bounded Tailscale
reconnect; it cannot trigger reboot or mutate settings.

## Recovery and firmware

| Module | Responsibility |
| --- | --- |
| `PlcRemote.Recovery.FSM` | Explicit outage escalation lifecycle |
| `PlcRemote.Recovery.Runtime` | Alarm subscription and stage timer scheduling |
| `PlcRemote.Recovery.Actions` | Reconnect/reapply/cycle/restart/reboot effects |
| `PlcRemote.Recovery.Policy` | Pure escalation ordering |
| `PlcRemote.Recovery.Safety` | Pure validated-firmware and reboot-budget guard |
| `PlcRemote.Recovery.RebootBudget` | Named persistent reboot-budget API |
| `PlcRemote.Firmware.FSM` | Validated/candidate/failure/revert lifecycle |
| `PlcRemote.Firmware.Runtime` | Health evidence and conservative decision deadlines |
| `PlcRemote.Firmware.Policy` | Pure validation/rollback policy |
| `PlcRemote.Firmware.Actions` | Slot validation, revert, and update-expectation effects |

## Supervision

```text
PlcRemote.Supervisor (:rest_for_one)
├── Configuration
├── Phoenix.PubSub / Events
├── Health.Reporter
├── Panel.Runtime
├── Network.Runtime
├── Tailscale.Supervisor (:one_for_all)
├── Service.Supervisor (:one_for_all)
├── Recovery.Runtime + linked Recovery.FSM
└── Firmware.Runtime + linked Firmware.FSM
```

## Invariants

1. Disable every detected Ethernet interface before applying active roles.
2. Identify Ethernet roles by hardware path, never `ethN`.
3. Internet is Ethernet-only; `wlan0` is AP-only.
4. Never give the PLC interface a gateway or DNS.
5. Never bridge or route/NAT the PLC subnet; service NAT may target only the Internet role.
6. Enable scoped IPv4 forwarding only while IN1 requests the service AP.
7. Never persist, publish, inspect, or render a Tailscale auth key.
8. Open no PLC listener without an enabled, successfully resolved PLC role.
9. Keep effect tasks/listeners and their lifecycle in one supervision lifetime.
10. Persist Tailscale enablement only after candidate enrollment succeeds.
11. Automatically reboot only validated firmware within the persisted budget.
12. Keep operational status separate from Health alarms.
13. Treat OUT1/OUT2 as non-safety indication outputs and initialize them off.
14. Let only confirmed-high IN1 disable service; keep IN2 limited to reconnect.

## Validation

```sh
mix ci
MIX_TARGET=rpi4 mix compile --force --warnings-as-errors
MIX_TARGET=rpi5 mix compile --force --warnings-as-errors
```

`mix ci` includes host quality gates plus real x86 Nerves/QEMU boot,
VintageNet, NIF, PLC-path, persistence, and link-state coverage. Hardware-affecting changes additionally require UART-observed CM4/CM5
boots, hardware-path confirmation, setup/GPIO AP checks, live-tailnet enrollment,
and a real PLC proxy test.
