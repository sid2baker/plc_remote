# Operations

> #### IPCBOX-CM5-A module requirement
>
> Use a CM5 for complete carrier operation. The board enables its four Type-A
> USB ports from module pin 111 (`VBUS_EN` on CM5), but CM4 assigns that pin to
> `VDAC_COMP`. With CM4, the USB keyboard, hub and USB-attached 2.5 Gb Ethernet
> controller therefore remain unpowered. The CM4 image keeps USB2 in device mode
> so the carrier's Type-C connector can provide a recovery network instead.

## Local service access

The WPA2 service WLAN is continuously enabled. IPCBOX IN1 is observed for
diagnostics but does not control the WLAN; terminal high, terminal low/open,
and unreadable/unavailable GPIO states all leave it on. Retrieve the per-device
WLAN credential through local UART/USB IEx:

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
Inspect detected interfaces with:

```elixir
PlcRemote.Network.status().interfaces
```

On IPCBOX-CM5-A, use CM5 so `VBUS_EN` powers the Type-A ports and USB-attached
second Ethernet controller. The CM4 image uses USB2 device mode for Type-C
recovery; its kernel retains RTL815x, AX88179, CDC Ethernet/NCM and R8169 drivers
for qualification on other carriers.

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

- IN1 / GPIO23: inverted isolated input observed for diagnostics only.
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

Before deployment, verify on CM5-equipped IPCBOX-CM5-A hardware:

- all Type-A USB ports and both Ethernet controllers;
- both Ethernet controllers' stable hardware paths;
- actual driver identity and speed;
- IN1/IN2 polarity and debounce;
- WPA2 AP remains active for high, low/open, and unavailable IN1 states;
- service-client Internet access and denied PLC-subnet routing;
- Tailscale candidate failure followed by a successful retry;
- fixed PLC proxy traffic and real PLC timing;
- repeated reboot and power-loss behavior.
