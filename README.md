# PLC Remote

Nerves firmware for simple, fail-closed remote access to one industrial PLC. The
primary platform is the
[Waveshare IPCBOX-CM5-A](https://docs.waveshare.com/IPCBOX-CM5-A) populated with
either a CM4 (`rpi4`) or CM5 (`rpi5`). Both targets use carrier-specific Nerves
systems.

PLC Remote has three physical network roles:

1. **Internet Ethernet** — connects to the site router and Tailscale.
2. **PLC Ethernet** — isolated static LAN connected only to the PLC.
3. **Service Wi-Fi** — WPA2 local service AP controlled directly by IPCBOX IN1.

It never bridges or advertises the PLC subnet. While the service AP is active,
it NATs only `wlan0` traffic to the configured Internet Ethernet interface;
forwarding from `wlan0` to the PLC interface is explicitly rejected.

## Traffic model

```text
Technician at home
      |
      | Tailscale TCP <gateway 100.x.y.z>:102
      v
PLC Remote userspace listener
      |
      | one fixed TCP proxy
      v
Configured PLC IPv4:102

Internet router <-- Ethernet [ PLC Remote ] Ethernet --> PLC
                              |
                              +-- WPA2 service AP -> Internet Ethernet only
```

The remote PLC path is one allowlisted stream:

```text
<gateway Tailscale IPv4>:102 -> <configured PLC IPv4>:102
```

The remote client receives no route to the PLC LAN. Broadcast traffic,
PROFINET/DCP discovery, Layer 2 protocols, and unrelated PLC hosts or ports do
not cross the proxy.

## Configuration

1. Put the cabinet service switch in its active position so IN1 is low.
2. Join the WPA2 `PLC-Remote-<serial>` WLAN.
3. Open `http://plc.setup/` or `http://192.168.50.1/`.
4. Inspect the live list of detected Ethernet controllers and cable state.
5. Select DHCP or enter a static Internet address if the plant requires it.
6. Configure the separate PLC controller when a second controller is detected.
7. Paste a one-use Tailscale auth key and select **Test key and connect**.

The auth key is checked for a plausible format and used against a temporary
candidate identity. Failed authentication leaves the saved configuration
unchanged and the form ready for another key. Only a successful tailnet join
promotes the identity and persists Tailscale as enabled. The auth key itself is
never persisted.

## Network safety

Ethernet roles are persisted by stable `/devices/...` hardware paths, not by
`eth0` or `eth1`. On boot and every role update, PLC Remote:

1. Detects physical Ethernet interfaces.
2. Disables all of them.
3. Resolves configured paths.
4. Enables only valid, distinct Internet and PLC roles.

A missing, duplicate, or reordered interface therefore fails closed. The PLC
LAN has a static local address but no gateway or DNS. IPv6 forwarding,
redirects, and source routing stay disabled. IPv4 forwarding is enabled only
while the service AP is active and is constrained by generated firewall rules.

`wlan0` has one purpose: the service AP. PLC Remote never scans for Wi-Fi WAN,
never joins a station network, and never transitions between AP and station
modes.

## Tailscale and PLC proxy

PLC Remote uses experimental `tailscale-rs` v0.4.0 rather than `tailscaled`.
The required acknowledgement is set in `vm.args` before the native library
loads:

```text
TS_RS_EXPERIMENT=this_is_unstable_software
```

This release identifies itself as unstable, unaudited, and DERP-only. Treat it
accordingly and restrict access with tailnet ACLs/grants.

The pinned `sid2baker/s7` library remains available independently in IEx:

```elixir
plc = PlcRemote.Configuration.current().machine.plc_address
{:ok, client} = S7.connect(plc, rack: 0, slot: 2, reconnect: true)
{:ok, value} = S7.read(client, "DB1.DBW0")
:ok = S7.close(client)
```

## Service switch

IPCBOX IN1 directly owns the service AP:

- confirmed high: AP off;
- low: AP on;
- unavailable or unreadable: AP on, so local recovery remains possible.

IN1 is GPIO23 (CM5 label `PIN16`) and active-low after isolation. Input changes
are debounced for contact bounce; there is no hold timer or inactivity timeout.
The service network is `192.168.50.0/24` and uses the per-device WPA2 key.

The remaining carrier I/O has deliberately narrow appliance semantics:

- IN2 / GPIO24: hold 3 seconds to request one Tailscale reconnect, rate-limited
  to once per 30 seconds. It cannot reboot, reset settings, or alter networking.
- OUT1 / GPIO27: on only while the tailnet listener and resolved PLC Ethernet
  path are both ready.
- OUT2 / GPIO22: on only while the service AP is active.
- USER1 / GPIO25: lit when enabled remote access is unavailable; off when
  Tailscale is disabled or connected.
- USER2 / GPIO26: lit on service GPIO/AP fault; off otherwise.

OUT1/OUT2 are indication outputs only, not safety outputs. Waveshare specifies
open-drain outputs (150 V cutoff, 500 mA maximum, 18 Ω on-resistance); external
loads still require engineering for inrush, suppression, fusing, and the
installation's electrical rules.

A prolonged Tailscale outage escalates through reconnect, Ethernet role reapply,
Internet Ethernet cycle, and a complete Tailscale supervisor restart before a
bounded reboot is considered. The persistent reboot budget prevents loops.

Retrieve service credentials over local UART/USB IEx:

```elixir
PlcRemote.Configuration.service_credentials()
PlcRemote.Diagnostics.snapshot()
PlcRemote.Diagnostics.explain()
PlcRemote.Health.active_alarms()
PlcRemote.Service.status()
```

## Firmware safety

Tentative A/B firmware is validated using product-level evidence. A new device
must provide its service AP and report observed network hardware. A configured
device must retain stable Tailscale connectivity. Proven pre-update remote
connectivity allows rollback when a candidate loses access; an ordinary ISP
outage is not mistaken for firmware regression.

Production OTA still requires deployment signing keys and signature-enforcing
transport.

## Hardware

`MIX_TARGET=rpi4` and `MIX_TARGET=rpi5` use
[`systems/plc_remote_system_rpi4`](systems/plc_remote_system_rpi4) and
[`systems/plc_remote_system_rpi5`](systems/plc_remote_system_rpi5). Both include
the native Raspberry Pi Ethernet driver and common second-port drivers:

- Realtek RTL8152/RTL8153/RTL8156 (`CONFIG_USB_RTL8152`)
- ASIX AX88179/178A (`CONFIG_USB_NET_AX88179_178A`)
- CDC Ethernet/NCM standards-based USB adapters
- Realtek PCIe fallback (`CONFIG_R8169`)

VintageNet boots both `eth0` and `eth1` disabled, then PLC Remote assigns roles
by discovered `/devices/...` hardware path. It never assumes which physical
socket Linux names `eth0` or `eth1`, so enumeration differences between CM4 and
CM5 cannot swap the Internet and PLC networks.

Physical qualification must still confirm both ports, the actual 2.5G
controller/driver, hardware paths, IN1/IN2 polarity, USER LED polarity, and
OUT1/OUT2 electrical behavior on each production variant.

## Persistent state

- Settings: `/data/plc_remote/settings.json`
- Tailscale identity: `/data/plc_remote/tailscale/keys.json`
- Recovery budget: `/data/plc_remote/recovery.json`
- OTA expectation: `/data/plc_remote/update-expectation.json`

Files and parent directories are owner-only. Tailscale auth keys are transient:
they are filtered from logs and never written to settings or returned to the
browser.

## Dependencies

- [`sid2baker/s7`](https://github.com/sid2baker/s7), commit
  `dc4665cf780ef8b9b753040faf86b02c28e24d44`
- [`tailscale/tailscale-rs`](https://github.com/tailscale/tailscale-rs), tag
  `v0.4.0`, `ts_elixir` subproject
- Phoenix LiveView and Bandit for the live local configuration page
- Finitomata for explicit Tailscale, Service, Recovery, and Firmware lifecycles
- Alarmist for primitive and derived persistent health conditions
- VintageNet and Circuits.GPIO for target networking and service recovery
- Volt 0.17.10 as a host-only TypeScript/CSS build tool

The reproducible patch under `patches/` prevents a reproduced upstream netmon
shutdown race from panicking a Tokio worker. `scripts/apply-dependency-patches.sh`
applies it before target compilation and fails if the pinned source no longer
matches.

## Development

```sh
mise install
rustup target add aarch64-unknown-linux-gnu x86_64-unknown-linux-musl --toolchain 1.95.0
mix archive.install hex nerves_bootstrap
mix deps.get
mix assets.build
mix ci
```

Local portal preview:

```sh
iex -S mix
# The host adapter treats unavailable IN1 as AP-on.
# http://127.0.0.1:4000/
```

Build firmware:

```sh
MIX_TARGET=host mix assets.build
MIX_TARGET=rpi4 mix firmware
MIX_TARGET=rpi5 mix firmware
MIX_TARGET=x86_64 mix firmware

# Boots and tests real x86_64 firmware in QEMU
mix test.firmware
```

The default `mix ci` finishes by running the deterministic QEMU lane. It boots
the real x86_64 Nerves firmware with two fixed virtio Ethernet devices. It verifies OTP supervision, stable role paths,
DHCP Internet, QMP link control, an isolated PLC echo, persistent settings, and
real loading of the musl `tailscale-rs` Rustler NIF. It does not require a
Tailscale credential.
GitHub Actions runs the same secret-free lane under QEMU TCG on pushes and pull
requests and retains QEMU logs and the x86 firmware as short-lived artifacts.
Live enrollment and fixed-proxy interoperability run only from the manual
`tailnet-integration` GitHub environment, which must be configured with required
reviewers, using a restricted CI tailnet tag. See `docs/operations.md` for credential and ACL requirements.

See [`docs/architecture.md`](docs/architecture.md),
[`docs/operations.md`](docs/operations.md), and
[`docs/code-map.md`](docs/code-map.md).

PLC Remote is available under the [MIT License](LICENSE).
