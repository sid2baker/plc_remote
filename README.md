# PLC Remote

Nerves firmware for physically commissioned, fail-closed remote access to an
industrial PLC. The primary CM5 platform is the
[Waveshare IPCBOX-CM5-A](https://docs.waveshare.com/IPCBOX-CM5-A).

PLC Remote uses the experimental Elixir bindings from `tailscale-rs` to expose
one explicitly configured PLC TCP endpoint. An uncommissioned gateway starts a
passwordless setup WLAN automatically and closes it only after successful
Tailscale enrollment. It does **not** bridge networks or advertise the PLC
subnet.

## Traffic model

```text
Authorized Tailscale client
            |
            | TCP <gateway tailnet IP>:102
            v
    tailscale-rs userspace listener
            |
            | fixed allowlisted proxy
            v
PLC / machine LAN <-- 1000M [ IPCBOX-CM5-A ] 2500M --> Internet
                                  |
                               Wi-Fi --> optional Internet fallback
```

The default proxy is:

```text
<gateway Tailscale IPv4>:102 -> <configured PLC IPv4>:102
```

From another Tailscale client, enter the gateway's displayed Tailscale IPv4 as
the S7 target. For Siemens S7comm, the client connects on TCP port 102 and PLC
Remote forwards the stream to the configured PLC address. Tailnet policy must
allow the operator to reach the gateway on that port.

This is intentionally limited:

- The remote client does not receive a route to the PLC subnet.
- Only the configured TCP destination is reachable.
- PROFINET/DCP discovery, broadcast traffic, and Layer 2 protocols do not cross
  the proxy. Configure the target by address.
- One gateway identity and TCP port map to one PLC endpoint. Additional PLCs or
  protocols require explicit additional proxy mappings.

### Connecting from a technician client

1. Connect the native 1000M port to the PLC network and the USB 2500M port to
   an Internet router, normally using DHCP.
2. Join the passwordless `PLC-Remote-<serial>` WLAN and open `http://plc.setup/`.
3. Select the detected native port for the machine LAN, enable it, and enter the
   gateway and PLC IPv4 addresses on the same subnet. Select the USB port and
   use **Automatic — Ethernet preferred** when a Wi-Fi fallback is desired.
4. Create a non-ephemeral Tailscale auth key, preferably restricted to a tag such
   as `tag:plc-gateway`; tagged devices avoid normal node-key expiry.
5. Enable Tailscale in the portal, enter the tag and one-time auth key, and
   permit the technician identity to reach that tag on TCP/102 in tailnet policy.
6. After enrollment, the setup WLAN closes. From a Tailscale-connected computer
   at home, use the gateway's `100.x.y.z` address as the S7/TIA target. TCP/102
   is relayed only to the configured PLC TCP/102 endpoint.

No subnet route or `--accept-routes` client setting is required for this proxy.

`tailscale-rs` 0.4.0 describes itself as unstable, unaudited, DERP-only software.
PLC Remote sets its required experiment acknowledgement because this project
explicitly chooses that implementation. Do not treat it as equivalent to the
audited production Tailscale client.

## Network roles

Both Ethernet ports are disabled on an uncommissioned unit. The portal lists
all detected ports with their driver, speed, link state, MAC address, and
VintageNet hardware path. Commissioning persists the selected paths rather
than `eth0`/`eth1`, since Linux enumeration may change between boots.

- The native, non-USB 1000M port is assigned to the isolated machine LAN.
  It receives a static address without a gateway or DNS server.
- The USB 2500M / `r8152` port is assigned to the preferred Internet uplink.
- `wlan0` is an optional Internet uplink in normal mode and the service access
  point in service mode.
- `usb0` provides local Nerves recovery and IEx access.

VintageNet's separate ifname-based persistence is disabled so stale `ethN`
settings cannot activate before role resolution. At every assignment change and
hardware discovery event, PLC Remote first disables every detected Ethernet
interface and then applies only valid, distinct hardware-path roles. A missing
or duplicate assignment therefore fails closed. It does not bridge, NAT, or
enable kernel packet forwarding. The PLC subnet must not overlap an uplink or
the service subnet.

### Ethernet-to-Wi-Fi failover

In automatic mode both Internet uplinks are configured concurrently. VintageNet
prefers Ethernet while it has Internet connectivity and selects Wi-Fi when the
wired route loses Internet. `tailscale-rs` reconnects through the selected
default route. The retry sequence begins around 5 seconds and backs off with
jitter to a maximum of 5 minutes.

### Bounded recovery

A prolonged Tailscale outage escalates through reconnect, network reapply,
uplink cycle, and a complete Tailscale-supervisor restart before considering a
device reboot. The default final threshold is 60 minutes. At most two
consecutive recovery reboots are allowed, and that persistent budget resets
only after 10 minutes of stable Tailscale connectivity.

Automatic reboot is disabled while commissioning or service mode is active and
while candidate firmware is unvalidated. If the budget cannot be persisted, the
reboot is cancelled. Operators can disable reboot recovery or adjust its
timeout and budget in the portal.

## IPCBOX-CM5-A support

`MIX_TARGET=rpi5` uses the local system in
[`systems/plc_remote_system_rpi5`](systems/plc_remote_system_rpi5). It is based
on `nerves_system_rpi5` 2.1.1 and enables the common USB 2.5G Ethernet drivers:

- Realtek RTL8152/RTL8153/RTL8156 via `CONFIG_USB_RTL8152`
- ASIX AX88179/178A via `CONFIG_USB_NET_AX88179_178A`

Waveshare's public schematic identifies the second port only as a “USB 2.5G ETH
Module”. On the first production unit, use the portal diagnostics to verify the
runtime driver and that the 1000M and 2500M physical ports have been assigned to
the intended roles.

The enclosure exposes two isolated digital inputs. Service mode defaults to
**DI1**, documented by Waveshare as GPIO23 and active-low at the CPU. The CM5
device tree exposes it to Circuits.GPIO as `GPIO23`.

The legacy `rpi4` target remains available with the stock CM4 system. Its
carrier-specific second Ethernet driver still depends on the CM4 hardware.

## First-boot commissioning and GPIO recovery

An uncommissioned target automatically creates the passwordless
`PLC-Remote-<serial>` setup WLAN. It serves DHCP, captive wildcard DNS, and the
portal at `http://plc.setup/` (`192.168.50.1`). No GPIO action or initial Wi-Fi
password is required.

The open WLAN stays up while Ethernet and Tailscale are being configured. PLC
Remote marks itself commissioned only after all of these are true:

1. The machine and uplink hardware paths resolve to distinct detected ports.
2. Network settings were applied without an error.
3. `tailscale-rs` obtained a tailnet address and started the fixed PLC listener.
4. The commissioned marker was atomically persisted.

It then shuts down the open WLAN. A failed enrollment or persistence operation
does not strand the installer; commissioning remains available and retries.
Because initial Wi-Fi and captive HTTP are unencrypted, commission in a
physically controlled area with a short-lived, single-use Tailscale auth key.
After commissioning, the open WLAN never reappears automatically. Local
recovery requires the configured GPIO hold and uses the persisted WPA2 password
with a 15-minute inactivity timeout.

Recovery defaults for IPCBOX-CM5-A are:

- input: DI1 / `GPIO23`
- active level: low
- hold: 3 seconds
- inactivity timeout: 15 minutes
- portal subnet: `192.168.50.0/24`

A single radio cannot be a Wi-Fi WAN client and service AP simultaneously. The
wired uplink can remain connected, but the web server binds only to the service
address.

The responsive website edits (and includes a PWA manifest):

- detected Ethernet diagnostics and stable hardware-path role assignment
- machine gateway and PLC addresses
- offline, automatic, Ethernet-only, or Wi-Fi-only uplink selection
- DHCP or static Ethernet/Wi-Fi addressing
- Wi-Fi credentials and regulatory domain
- Tailscale hostname, requested tags, one-time auth key, listener port, and PLC port
- service GPIO, active level, hold time, timeout, SSID, and WPA2 password
- automatic recovery reboot enablement, timeout, and persistent reboot budget

The captive portal uses HTTP so automatic browser opening works without a
certificate warning. Consequently, service-worker/offline PWA features are
activated only if the site is later served in a browser-secure HTTPS context.

Settings and Tailscale identity state are stored with owner-only permissions
under `/data/plc_remote`. The auth key is passed directly to the connection
manager and is never written into settings, HTML, browser storage, or the PWA
cache.

A random WPA2 password is generated for post-commissioning GPIO recovery. It is
not required for the initial open WLAN. Retrieve it over local USB IEx for
labeling or manufacturing provisioning:

```elixir
PlcRemote.Configuration.service_credentials()
```

Service mode and recovery state can also be controlled from local UART/USB IEx:

```elixir
PlcRemote.ServiceMode.activate()
PlcRemote.RecoveryManager.status()
PlcRemote.RecoveryManager.reset_reboot_budget()
```

## OTA firmware safety

Tentative A/B firmware is no longer validated merely because OTP started. The
OTA agent first calls `PlcRemote.FirmwareValidator.prepare_for_update/0` while
the old image is connected. An uncommissioned candidate must bring up its setup
AP; a commissioned image must keep Tailscale connected for one minute. If ordinary Internet works but Tailscale
cannot recover for 45 minutes, PLC Remote reverts to the previous slot. An ISP
outage does not trigger rollback or reboot of an unvalidated image.

Keep settings schema changes additive until candidate validation. This allows
the previous firmware slot to read the same `/data/plc_remote/settings.json`
without onsite reconfiguration after rollback.

## Dynamic S7 access from IEx

The pinned `sid2baker/s7` library is included in both firmware targets for
interactive diagnostics and configuration. It does not have to be running for
the remote TCP proxy to work.

```elixir
plc = PlcRemote.Configuration.get().machine.plc_address
{:ok, client} = S7.connect(plc, rack: 0, slot: 2, reconnect: true)
{:ok, value} = S7.read(client, "DB1.DBW0")
:ok = S7.close(client)
```

Writes and destructive programmer operations should be enabled only during an
explicit maintenance session; the library requires separate opt-ins for its
destructive APIs.

## Dependencies

- [`sid2baker/s7`](https://github.com/sid2baker/s7), commit
  `dc4665cf780ef8b9b753040faf86b02c28e24d44`; included for dynamic PLC work
  from the Nerves IEx shell, but not coupled to the fixed TCP proxy
- [`tailscale/tailscale-rs`](https://github.com/tailscale/tailscale-rs), tag
  `v0.4.0`, using its `ts_elixir` project
- VintageNet, Circuits.GPIO, Plug, and Bandit for target networking and local
  commissioning

Target integrations live under `target/` and are selected through adapters in
`config/target.exs`. Application logic has no scattered host/target branches;
host-only development adapters live under `host/`.

For maintainers:

- [`docs/code-map.md`](docs/code-map.md) explains module ownership, change
  locations, and non-negotiable safety invariants.
- [`docs/architecture.md`](docs/architecture.md) explains trust zones, data
  paths, commissioning, and supervision failure boundaries.
- [`docs/operations.md`](docs/operations.md) defines retry timing, reboot escape
  hatches, OTA validation, and evidence-based rollback.

## Development

The checked-in `.tool-versions` specifies Erlang, Elixir, Rust, and `fwup`.

```sh
mise install
rustup target add aarch64-unknown-linux-gnu --toolchain 1.95.0
mix archive.install hex nerves_bootstrap
mix deps.get
mix ci
```

Preview the service website locally:

```sh
iex -S mix
PlcRemote.ServiceMode.activate()
# Open http://127.0.0.1:4000/
```

## Firmware

```sh
MIX_TARGET=rpi5 mix deps.get
MIX_TARGET=rpi5 mix firmware
```

The first custom-system build compiles Buildroot and Linux and is substantially
slower than later firmware builds.

For CM5 Lite, burn to microSD with `MIX_TARGET=rpi5 mix burn`. For CM5 eMMC,
expose eMMC with the BOOT button and `rpiboot`, then burn to the resulting host
block device.
