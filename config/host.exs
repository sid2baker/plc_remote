import Config

# Add configuration that is only needed when running on the host here.

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

config :plc_remote,
  settings_path: nil,
  recovery_state_path: nil,
  update_expectation_path: nil,
  default_service_gpio: "GPIO17",
  service_port: 4000,
  auto_commissioning: false,
  uplink_cycle_delay_ms: 0,
  network_adapter: PlcRemote.Adapters.Host.Network,
  gpio_adapter: PlcRemote.Adapters.Host.GPIO,
  device_adapter: PlcRemote.Adapters.Host.Device,
  system_adapter: PlcRemote.Adapters.Host.System,
  tailscale_adapter: PlcRemote.Adapters.Host.Tailscale

config :nerves_uevent, manage_udev: false
