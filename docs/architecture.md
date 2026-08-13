# PLC Remote architecture

PLC Remote exposes one configured PLC TCP endpoint over embedded `tailscale-rs`.
It does not bridge or advertise the PLC subnet.

## Physical networks

| Role | Interface | Addressing | Purpose |
|---|---|---|---|
| Internet | detected Ethernet path | DHCP or static | Internet and Tailscale |
| PLC | separate detected Ethernet path | static, no gateway/DNS | One fixed userspace PLC proxy |
| Service | `wlan0` | `192.168.50.1/24` | WPA2 local status/configuration |
| Recovery | `usb0` | Nerves default | Local IEx and firmware access |

Ethernet roles are persisted by `/devices/...` hardware path. All detected
Ethernet interfaces are disabled before valid, distinct roles are enabled.
A missing or duplicate role fails closed.

The IPCBOX second Ethernet controller is USB-attached. Full carrier operation
requires CM5 because the board powers its Type-A ports from CM5-only `VBUS_EN`
on module pin 111; CM4 assigns that pin to `VDAC_COMP`. The CM4 IPCBOX image
keeps USB2 in device mode for Type-C recovery instead. Its kernel retains
RTL815x, AX88179, CDC Ethernet/NCM and R8169 drivers for qualification on other
carriers. If only one controller enumerates, the UI reports that Internet can work but isolated PLC
access needs a second controller; it never invents or assumes `eth1`.

## Service switch and routing

IPCBOX IN1 directly controls the AP after a short debounce. The isolated carrier
input inverts the external terminal level:

```text
terminal high (>2 V) -> GPIO low  -> AP on
terminal low/open     -> GPIO high -> AP off
GPIO unreadable                    -> AP on
```

Only a confirmed inactive GPIO level may remove onsite service access. The AP always uses the
per-device WPA2 key. There is no first-boot open AP, hold timer, inactivity
timeout, final handoff, or browser-owned lifecycle.

While active, the AP provides DHCP and public DNS servers. Scoped iptables rules
allow only:

```text
wlan0 -> configured Internet Ethernet -> MASQUERADE
Internet Ethernet -> wlan0             -> RELATED,ESTABLISHED only
wlan0 -> every other forwarding path   -> REJECT
```

The rules and IPv4 forwarding are removed when the isolated IN1 terminal goes low/open. IPv6 forwarding
remains disabled. No service traffic can route to the PLC Ethernet role.

## Configuration UI

One LiveView page refreshes the operational read models and shows every detected
network controller, driver, MAC, stable path, link state and current addresses.
It presents DHCP first and static fields for networks that require them. PLC
settings remain disabled until two Ethernet controllers are visible.

Tailscale enrollment is transactional:

1. reject missing or implausible `tskey-auth-...` input locally;
2. build validated candidate settings without persisting them;
3. connect using a temporary candidate identity file;
4. require an IPv4 address and stable node identity;
5. atomically promote the identity and persist enabled settings only on success;
6. remove candidate state and return a secret-free error on failure.

The auth key is never stored, published, inspected, rendered, or logged.

## Runtime flow

```text
observation -> Alarmist health -> policy/FSM event -> Finitomata transition
            -> action -> target adapter
```

Lifecycle belongs to Finitomata FSMs. Alarmist represents persistent health,
not commands. Typed statuses are operational read models.

## Supervision

```text
PlcRemote.Supervisor (:rest_for_one)
├── Configuration
├── Phoenix.PubSub / Events
├── Health.Reporter
├── Panel.Runtime
├── Network.Runtime
├── Tailscale.Supervisor
├── Service.Supervisor
├── Recovery.Runtime
└── Firmware.Runtime
```

The service supervisor owns the web runtime, temporary Bandit listener, IN1
resource and Service FSM. Restarting it re-reads IN1 and restores the requested
state.

## Security invariants

- Never persist or publish Tailscale credentials.
- Never bridge interfaces.
- Never route, NAT or advertise the PLC subnet.
- Bind PLC egress to the resolved PLC interface.
- Open no PLC listener until the PLC role is enabled, resolved and applied.
- Use `wlan0` only as a WPA2 AP, never as a station.
- Enable service routing only while IN1 requests the AP.
- Keep IPv6 forwarding disabled.
