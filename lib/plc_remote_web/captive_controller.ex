defmodule PlcRemoteWeb.CaptiveController do
  use Phoenix.Controller, formats: [:html]

  @spec redirect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redirect(conn, _params) do
    conn
    |> put_resp_header("location", "http://plc.setup/")
    |> send_resp(302, "")
  end

  @spec exit_service(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def exit_service(conn, _params) do
    send_resp(conn, 409, "Service WLAN is controlled only by IPCBOX IN1.")
  end
end
