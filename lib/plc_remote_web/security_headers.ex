defmodule PlcRemoteWeb.SecurityHeaders do
  @moduledoc false

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store, max-age=0")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; connect-src 'self' ws://plc.setup ws://192.168.50.1; " <>
        "object-src 'none'; " <>
        "frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    )
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
  end
end
