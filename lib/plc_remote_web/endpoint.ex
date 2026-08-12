defmodule PlcRemoteWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :plc_remote

  @session_options [
    store: :cookie,
    key: "_plc_remote_service",
    signing_salt: "service-mode-v2",
    same_site: "Strict",
    http_only: true,
    secure: false,
    max_age: 7_200
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: {:plc_remote, "priv/static"},
    gzip: false,
    only: ~w(assets)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["application/x-www-form-urlencoded"],
    length: 64_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PlcRemoteWeb.SecurityHeaders
  plug PlcRemoteWeb.Router
end
