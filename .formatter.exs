# Used by "mix format"
[
  plugins: [Phoenix.LiveView.HTMLFormatter, Volt.Formatter],
  import_deps: [:phoenix],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,host,lib,target,test}/**/*.{ex,exs,heex}",
    "integration/firmware/**/*.{ex,exs}",
    "assets/**/*.{js,ts}",
    "systems/*/mix.exs",
    "rootfs_overlay/etc/iex.exs"
  ]
]
