defmodule PlcRemote.MixProject do
  use Mix.Project

  @app :plc_remote
  @version "0.1.0"
  @all_targets [:rpi4, :rpi5]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.target()),
      archives: [nerves_bootstrap: "~> 1.16"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      dialyzer: [plt_add_apps: [:ex_unit]],
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger, :runtime_tools],
      mod: {PlcRemote.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [ci: :host, run: :host, test: :host], preferred_envs: [ci: :test]]
  end

  defp elixirc_paths(:host), do: ["lib", "host"]
  defp elixirc_paths(_target), do: ["lib", "target"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false, targets: :host},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false, targets: :host},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false, targets: :host},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false, targets: :host},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false, targets: :host},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false, targets: :host},
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Web-based commissioning UI shared by host tests and target firmware
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.12"},
      # Hardware support for CM4/CM5 targets
      {:circuits_gpio, "~> 2.3", targets: @all_targets},
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:s7, github: "sid2baker/s7", ref: "dc4665cf780ef8b9b753040faf86b02c28e24d44", depth: 1},
      {:tailscale,
       github: "tailscale/tailscale-rs",
       tag: "v0.4.0",
       subdir: "ts_elixir",
       depth: 1,
       targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:plc_remote_system_rpi5,
       path: "systems/plc_remote_system_rpi5",
       runtime: false,
       targets: :rpi5,
       nerves: [compile: true]}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
