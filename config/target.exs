import Config

# Rustler otherwise builds the Tailscale NIF for the host architecture. CM4/CM5
# use glibc AArch64 while the generic Nerves x86_64 system uses musl.
{rust_target, linker_env, default_linker, default_service_gpio, console_tty} =
  Map.fetch!(
    %{
      rpi4:
        {"aarch64-unknown-linux-gnu", "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER",
         "aarch64-nerves-linux-gnu-gcc", "GPIO23", "ttyS0"},
      rpi5:
        {"aarch64-unknown-linux-gnu", "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER",
         "aarch64-nerves-linux-gnu-gcc", "PIN16", "ttyAMA10"},
      x86_64:
        {"x86_64-unknown-linux-musl", "CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER",
         "x86_64-nerves-linux-musl-gcc", "emulated", "ttyS0"}
    },
    Mix.target()
  )

rust_linker = System.get_env("CC", default_linker)

rust_env =
  [{linker_env, rust_linker}]
  |> then(fn env ->
    if Mix.target() == :x86_64 do
      [
        {"RUSTFLAGS", "-C target-feature=-crt-static"},
        {"AWS_LC_SYS_TARGET_CFLAGS", "-fPIC"}
        | env
      ]
    else
      env
    end
  end)

config :tailscale, Tailscale.Native,
  target: rust_target,
  env: rust_env

ipcbox_io =
  if Mix.target() == :rpi5 do
    %{input_2: "PIN18", output_1: "PIN13", output_2: "PIN15", user_1: "PIN22", user_2: "PIN37"}
  else
    %{
      input_2: "GPIO24",
      output_1: "GPIO27",
      output_2: "GPIO22",
      user_1: "GPIO25",
      user_2: "GPIO26"
    }
  end

config :plc_remote,
  settings_path: "/data/plc_remote/settings.json",
  recovery_state_path: "/data/plc_remote/recovery.json",
  update_expectation_path: "/data/plc_remote/update-expectation.json",
  tailscale_key_file: "/data/plc_remote/tailscale/keys.json",
  default_service_gpio: default_service_gpio,
  fixed_service_gpio: Mix.target() in [:rpi4, :rpi5],
  ipcbox_io: ipcbox_io,
  panel_required: Mix.target() in [:rpi4, :rpi5],
  service_port: 80,
  network_adapter: PlcRemote.Adapters.Target.Network,
  gpio_adapter: PlcRemote.Adapters.Target.GPIO,
  device_adapter: PlcRemote.Adapters.Target.Device,
  service_router_adapter: PlcRemote.Adapters.Target.ServiceRouter,
  system_adapter: PlcRemote.Adapters.Target.System,
  tailscale_adapter: PlcRemote.Adapters.Target.Tailscale

if Mix.target() == :x86_64 do
  config :plc_remote,
    default_service_gpio: "emulated",
    fixed_service_gpio: false,
    ipcbox_io: nil,
    panel_required: false,
    gpio_adapter: PlcRemote.Integration.GPIO,
    service_router_adapter: PlcRemote.Integration.ServiceRouter,
    recovery_auto_start: false
end

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
# PlcRemote.Firmware performs assisted validation after local health and
# tailnet checks. The generic startup guard would validate as soon as OTP starts,
# which is too early to catch a firmware update that breaks remote connectivity.
config :nerves_runtime, startup_guard_enabled: false

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit,
  ctty: console_tty,
  update_clock: true

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

# Network roles are intentionally separated:
#
#   * eth0/eth1 - disabled until stable hardware paths are assigned to the
#                 isolated PLC LAN and Ethernet Internet roles
#   * wlan0     - setup/recovery access point only; never an Internet uplink
#   * usb0      - local recovery/commissioning connection
#
# Both Ethernet ports fail closed so kernel enumeration cannot swap the PLC and
# Internet roles. PlcRemote.Network.Runtime resolves persisted hardware paths on
# every boot, disables all detected Ethernet interfaces, and only then applies
# the assigned machine/uplink configurations.
#
# regulatory_domain controls only the local service access point.
# See https://github.com/nerves-networking/vintage_net for more information.
config :vintage_net,
  # PlcRemote.Configuration is the only persistence owner. Disabling
  # VintageNet's ifname-keyed persistence prevents a previously active ethN
  # configuration from being applied to a different physical port at boot.
  persistence: VintageNet.Persistence.Null,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :disabled}}},
    {"eth1", %{type: VintageNetEthernet, ipv4: %{method: :disabled}}},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :mdns_lite,
  # Advertise only the device's unique hostname. A shared `nerves.local` alias
  # is unsafe for fleets because any gateway could answer it.
  hosts: [:hostname],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    }
  ]

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
