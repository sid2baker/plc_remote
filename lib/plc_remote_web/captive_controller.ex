defmodule PlcRemoteWeb.CaptiveController do
  use Phoenix.Controller, formats: [:html]

  @spec redirect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redirect(conn, _params) do
    conn
    |> put_resp_header("location", "http://plc.setup/")
    |> send_resp(302, "")
  end
end
