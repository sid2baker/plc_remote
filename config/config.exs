# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1786372525"

config :alarmist,
  alarm_levels: %{
    PlcRemote.Health.Alarms.InternetUnavailable => :warning,
    PlcRemote.Health.Alarms.NetworkConfigurationInvalid => :error,
    PlcRemote.Health.Alarms.PlcInterfaceUnavailable => :warning,
    PlcRemote.Health.Alarms.RemoteAccessExpected => :debug,
    PlcRemote.Health.Alarms.TailscaleListenerUnavailable => :error,
    PlcRemote.Health.Alarms.TailscaleUnavailable => :warning
  }

config :finitomata,
  history_size: 5,
  telemetria_levels: :none,
  warn_ambiguous_start_fsm: false

config :phoenix,
  json_library: Jason,
  filter_parameters: ["password", "psk", "auth_key", "web_secret"]

config :plc_remote, PlcRemoteWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  check_origin: ["//plc.setup", "//192.168.50.1"],
  live_view: [signing_salt: "plc-remote-live-v1"],
  pubsub_server: PlcRemote.PubSub,
  render_errors: [formats: [html: PlcRemoteWeb.ErrorHTML], layout: false],
  server: false,
  url: [host: "plc.setup", port: 80, scheme: "http"]

config :volt,
  entry: ["assets/js/app.ts", "assets/css/app.css"],
  hash: false,
  minify: true,
  outdir: "priv/static/assets",
  root: "assets",
  sourcemap: false,
  sources: ["**/*.{js,ts}"],
  target: :es2020,
  resolve_dirs: ["deps", Mix.Project.build_path()]

config :volt, :format,
  semi: false,
  single_quote: true

config :volt, :lint,
  plugins: [:typescript],
  rules: %{"correctness" => :deny}

config_file =
  Map.fetch!(
    %{host: "host.exs", rpi4: "target.exs", rpi5: "target.exs", x86_64: "target.exs"},
    Mix.target()
  )

import_config config_file
