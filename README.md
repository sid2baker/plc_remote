# PLC Remote

Nerves firmware for simple, fail-closed remote access to one industrial PLC. The
primary CM5 platform is the
[Waveshare IPCBOX-CM5-A](https://docs.waveshare.com/IPCBOX-CM5-A); the stock CM4
`rpi4` target remains supported.

PLC Remote has three physical network roles:

1. **Internet Ethernet** — connects to the site router and Tailscale.
2. **PLC Ethernet** — isolated static LAN connected only to the PLC.
3. **Service Wi-Fi** — local setup/recovery AP only; never an Internet uplink.

It does not bridge, route, NAT, or advertise the PLC subnet.

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
                              +-- Wi-Fi setup/recovery AP only
```

The remote path is one allowlisted stream:

```text
<gateway Tailscale IPv4>:102 -> <configured PLC IPv4>:102
```

The remote client receives no route to the PLC LAN. Broadcast traffic,
PROFINET/DCP discovery, Layer 2 protocols, and unrelated PLC hosts or ports do
not cross the proxy.

## Commissioning

1. Connect one Ethernet port to an Internet router, normally with DHCP.
2. Join the passwordless `PLC-Remote-<serial>` setup WLAN.
3. Open `http://plc.setup/` or `http://192.168.50.1/`.
4. Select the detected Ethernet port connected to the router and save it.
5. Paste a short-lived Tailscale auth key and wait for enrollment.
6. Select **Finish setup**.

Ethernet Internet and Tailscale are verified while the setup AP remains active.
Only a successful final test closes the AP. A failed test leaves it available;
a reboot before success starts it again.

PLC addressing and assignment of the separate PLC Ethernet port are deliberately
outside this Internet/Tailscale wizard. Provision them during manufacturing or
from local IEx. Until provisioned, the gateway can join Tailscale but opens no
PLC listener.

## Network safety

Ethernet roles are persisted by stable `/devices/...` hardware paths, not by
`eth0` or `eth1`. On boot and every role update, PLC Remote:

1. Detects physical Ethernet interfaces.
2. Disables all of them.
3. Resolves configured paths.
4. Enables only valid, distinct Internet and PLC roles.

A missing, duplicate, or reordered interface therefore fails closed. The PLC
LAN has a static local address but no gateway or DNS. Kernel IPv4/IPv6 forwarding,
redirects, and source routing are disabled.

`wlan0` has one purpose: the service AP. PLC Remote never scans for Wi-Fi WAN,
never joins a station network, and never transitions between AP and station
modes during normal operation.

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
plc = PlcRemote.Configuration.get().machine.plc_address
{:ok, client} = S7.connect(plc, rack: 0, slot: 2, reconnect: true)
{:ok, value} = S7.read(client, "DB1.DBW0")
:ok = S7.close(client)
```

## Recovery

After commissioning, holding the configured physical input starts a WPA2,
time-limited service AP. IPCBOX-CM5-A defaults are:

- DI1 / `GPIO23`, active-low
- 3-second hold
- 15-minute inactivity timeout
- `192.168.50.0/24`

Onsite setting changes are transactional. A snapshot at
`/data/plc_remote/settings.json.service-rollback` is restored after exit,
timeout, failed verification, process failure, or power loss unless final
verification commits it.

A prolonged Tailscale outage escalates through reconnect, Ethernet role reapply,
Internet Ethernet cycle, and a complete Tailscale supervisor restart before a
bounded reboot is considered. The persistent reboot budget prevents loops.

Retrieve service credentials over local UART/USB IEx:

```elixir
PlcRemote.Configuration.service_credentials()
PlcRemote.NetworkManager.status()
PlcRemote.TailscaleManager.status()
PlcRemote.ServiceMode.activate()
PlcRemote.RecoveryManager.status()
```

## Firmware safety

Tentative A/B firmware is validated using product-level evidence. An
uncommissioned candidate must provide its setup AP. A commissioned candidate
must retain stable Tailscale connectivity. Proven pre-update remote connectivity
allows rollback when a candidate loses access; an ordinary ISP outage is not
mistaken for firmware regression.

Production OTA still requires deployment signing keys and signature-enforcing
transport.

## Hardware

`MIX_TARGET=rpi5` uses
[`systems/plc_remote_system_rpi5`](systems/plc_remote_system_rpi5), based on
`nerves_system_rpi5` 2.1.1. It enables common USB 2.5G Ethernet drivers:

- Realtek RTL8152/RTL8153/RTL8156 (`CONFIG_USB_RTL8152`)
- ASIX AX88179/178A (`CONFIG_USB_NET_AX88179_178A`)

Confirm physical port paths, driver identity, and DI1 polarity on each intended
carrier. A CM4 exposing only one Ethernet controller cannot provide both the
Internet and isolated PLC roles without a second controller.

## Persistent state

- Settings: `/data/plc_remote/settings.json`
- Service rollback: `/data/plc_remote/settings.json.service-rollback`
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
- Phoenix LiveView and Bandit for the local wizard
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
PlcRemote.ServiceMode.activate()
# http://127.0.0.1:4000/
```

Build firmware:

```sh
MIX_TARGET=host mix assets.build
MIX_TARGET=rpi4 mix firmware
MIX_TARGET=rpi5 mix firmware
MIX_TARGET=x86_64 mix firmware

# Requires QEMU x86_64, qemu-img, fwup, and Python 3
mix ci.integration
```

The default `mix ci` finishes by running the deterministic QEMU lane. It boots
the real x86_64 Nerves firmware with two fixed virtio Ethernet devices. It verifies OTP supervision, stable role paths,
DHCP Internet, QMP link control, persistent settings, invalid-key fail-closed
behavior, and real loading of the musl `tailscale-rs` Rustler NIF. It does not
require a Tailscale credential.
GitHub Actions runs the same secret-free lane under QEMU TCG on pushes and pull
requests and retains QEMU logs and the x86 firmware as short-lived artifacts.
Live enrollment and fixed-proxy interoperability run only from the manual
`tailnet-integration` GitHub environment, which must be configured with required
reviewers, using a restricted CI tailnet tag. See `docs/operations.md` for credential and ACL requirements.

See [`docs/architecture.md`](docs/architecture.md),
[`docs/operations.md`](docs/operations.md), and
[`docs/code-map.md`](docs/code-map.md).

PLC Remote is available under the [MIT License](LICENSE).
