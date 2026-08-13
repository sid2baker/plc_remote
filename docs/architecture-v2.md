# PLC Remote architecture v2

PLC Remote v2 separates observation, health, lifecycle, decision, and effect so
that field behavior can be explained without reconstructing state from several
OTP processes.

## The flow

```text
OBSERVATION
    ↓
ALARM
    ↓
POLICY / FSM EVENT
    ↓
FSM TRANSITION
    ↓
ACTION
    ↓
ADAPTER
```

- **Observations** are present facts: Ethernet Internet is available, a
  configured PLC interface exists, Tailscale is connected, the setup AP is
  healthy, or firmware is tentative.
- **Primitive alarms** are persistent independently observable conditions. Each
  primitive alarm has exactly one owning subsystem.
- **Derived alarms** express product meaning from primitive alarms and
  configuration. They have no imperative setter.
- **FSMs** express one mutually exclusive lifecycle state and accept domain
  events describing things that happened.
- **Policies** are pure functions answering what should happen from supplied
  facts.
- **Actions** order side effects but do not decide lifecycle or global health.
- **Adapters** are the only boundaries to hardware, operating-system, network,
  firmware-slot, and native Tailscale APIs.

## Required separation

`PlcRemote.Health` answers **what is wrong now**. It is a read model over
Alarmist and observations, not another source of truth.

Subsystem status answers **what that subsystem is doing**. Public statuses are
structs and never double as alarms.

Finitomata FSM state answers **which lifecycle the subsystem is in**. FSM state
is not used as a general alarm store.

Actions answer **what the appliance physically does**. FSM declarations and
pure policy modules do not invoke adapters directly.

## Prohibited patterns

New v2 code must not introduce:

1. one lifecycle process polling another process's `status/0` to infer global
   health;
2. FSM state used as an alarm system;
3. Alarmist used as a command or domain-event bus;
4. `safe_status/1` fallbacks that turn process failure into an empty map;
5. a persistent configuration event carrying a transient enrollment secret;
6. manually setting or clearing a derived alarm.

## Alarm ownership

Every primitive alarm has one owner. Owners clear their alarms when the
condition is resolved and clear/reset owned observations when their lifecycle
restarts so stale truth is not retained.

Initial ownership:

| Primitive alarm | Owner |
| --- | --- |
| `NetworkConfigurationInvalid` | `Network.Runtime` |
| `InternetUnavailable` | `Network.Runtime` |
| `PlcInterfaceUnavailable` | `Network.Runtime` |
| `PanelIOUnavailable` | `Panel.Runtime` |
| `TailscaleUnavailable` | `Tailscale.FSM` |
| `TailscaleListenerUnavailable` | `Tailscale.FSM` |
| `ServiceGPIOUnavailable` | `Service.GPIO` |
| `ServiceAPUnavailable` | `Service.FSM` / `Service.Actions` |
| `FirmwareCandidateUnvalidated` | `Firmware.FSM` |
| `FirmwareValidationFailed` | `Firmware.FSM` |
| `RecoveryRebootBudgetExhausted` | `Recovery.FSM` |

`RemoteAccessUnavailable` is derived from configuration facts and primitive
network/Tailscale conditions. No subsystem sets it directly.

## Events and credentials

Cross-domain events use `PlcRemote.Events` and named structs. Events report
facts that happened; they are not remote procedure calls.

Persistent configuration changes publish a non-secret `ConfigurationChanged`
event. Tailscale enrollment is a direct transient command containing a redacted
`Tailscale.Enrollment` value. Enrollment credentials are never persisted,
published, included in alarm metadata or public status, or rendered through
`Inspect`.

## Stable product invariants

The v2 implementation preserves the product architecture:

- Ethernet Internet and isolated PLC LAN are distinct hardware-path roles;
- every Ethernet application is disable-first and unassigned ports stay off;
- PLC configuration has no gateway or DNS;
- Wi-Fi is a WPA2 service AP only;
- the service AP remains continuously requested; IPCBOX IN1 is diagnostic only
  and IN2 can only request a bounded reconnect;
- IPCBOX outputs initialize off and remain non-safety indications;
- remote PLC access is one fixed userspace TCP destination, never subnet routing
  or bridging;
- service NAT is scoped to `wlan0` → Internet Ethernet and rejects every other
  forwarded service path;
- Tailscale enablement persists only after successful candidate enrollment;
- recovery remains staged and reboot-budgeted;
- tentative firmware rollback remains evidence-based and conservative;
- host/target adapters and real x86 Nerves/QEMU validation remain mandatory.

## Diagnostics

`PlcRemote.Diagnostics.snapshot/0` is the supported non-secret field readout. It
combines typed subsystem status with `PlcRemote.Health.snapshot/0` while keeping
operational lifecycle separate from health conditions.
