# Operations

## Local service access

IPCBOX IN1 directly controls the WPA2 service WLAN:

- high: WLAN off;
- low: WLAN on;
- unreadable/unavailable: WLAN on.

There is a short debounce for contact bounce and no hold duration or timeout.
Use the cabinet service switch to pull IN1 low. Retrieve the per-device WLAN
credential through local UART/USB IEx:

```elixir
PlcRemote.Configuration.service_credentials()
```

Then open `http://plc.setup/` or `http://192.168.50.1/`.

When Internet Ethernet is configured, service clients can use it through
scoped NAT. Traffic to the PLC Ethernet interface is rejected. Check:

```elixir
PlcRemote.Service.status()
PlcRemote.Network.status()
PlcRemote.Diagnostics.snapshot()
```

## Network setup

The portal continuously lists all detected interfaces with driver, MAC,
hardware path, link state and current addresses.

1. Connect the Internet cable.
2. Select the linked Ethernet controller.
3. Keep DHCP unless the site requires static addressing.
4. If two controllers are detected, enable the PLC role on the other controller.
5. Enter the gateway-side PLC LAN address and fixed PLC address.

If only one controller appears, Internet can work but isolated PLC access cannot.
On CM4, confirm that the USB-attached second controller enumerates:

```elixir
PlcRemote.Network.status().interfaces
```

The CM4 system forces its USB2 controller into host mode and includes RTL815x,
AX88179, CDC Ethernet/NCM and R8169 drivers. Physical qualification must still
confirm the actual IPCBOX module and cable path.

## Tailscale enrollment

Use a one-use, short-lived auth key. The portal:

1. validates the key shape;
2. tests it against a temporary candidate identity;
3. requires a tailnet IPv4 address and node identity;
4. promotes the identity and saves `tailscale.enabled` only after success.

Missing, malformed, rejected and timed-out keys leave saved settings unchanged.
The field stays available for another attempt. The key itself is never persisted.

Inspect status without exposing credentials:

```elixir
PlcRemote.Tailscale.status()
PlcRemote.Health.active_alarms()
RingLogger.grep(~r/network|tailscale|service|firmware/i)
```

## PLC path

The deployed path is:

```text
Tailscale peer -> gateway tailnet IPv4:102 -> fixed PLC IPv4:102
```

The listener remains unavailable until a distinct PLC Ethernet role is enabled,
resolved by stable hardware path, and successfully applied. The PLC interface
has no gateway or DNS.

Independent local S7 diagnostics remain available:

```elixir
plc = PlcRemote.Configuration.current().machine.plc_address
{:ok, client} = S7.connect(plc, rack: 0, slot: 2, reconnect: true)
{:ok, value} = S7.read(client, "DB1.DBW0")
:ok = S7.close(client)
```

## Carrier I/O

- IN1 / GPIO23: direct active-low service WLAN switch.
- IN2 / GPIO24: hold three seconds for one rate-limited Tailscale reconnect.
- OUT1 / GPIO27: remote PLC path ready.
- OUT2 / GPIO22: service WLAN active.
- USER1 / GPIO25: enabled remote access unavailable.
- USER2 / GPIO26: service GPIO/AP fault.

OUT1/OUT2 are indications, not safety outputs.

## Recovery and OTA

A prolonged remote-access outage escalates through reconnect, network reapply,
uplink cycle and Tailscale restart before a bounded reboot is considered.
Service access suppresses disruptive recovery while onsite work is active.

Tentative firmware validates only after service and network observations on a
new device, or stable tailnet evidence on a configured device. Production OTA
still requires signing keys and signature-enforcing transport.

## Firmware tests

```sh
mix test.firmware
```

This boots real x86_64 Nerves firmware in QEMU and verifies the native NIF,
VintageNet roles, isolated PLC TCP path, link changes, shutdown and persistence.
Protected tailnet tests remain manual:

```sh
mix test.invalid-key
mix ci.tailnet
```

## Physical acceptance

Before deployment, verify on both CM4 and CM5:

- both Ethernet controllers and stable hardware paths;
- actual driver identity and speed;
- IN1/IN2 polarity and debounce;
- WPA2 AP enable/disable from the cabinet switch;
- service-client Internet access and denied PLC-subnet routing;
- Tailscale candidate failure followed by a successful retry;
- fixed PLC proxy traffic and real PLC timing;
- repeated reboot and power-loss behavior.
