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
    if PlcRemote.ServiceMode.status().mode == :automatic do
      send_resp(conn, 409, "First-boot setup must pass verification before the AP can close.")
    else
      Task.start(fn ->
        Process.sleep(750)
        PlcRemote.ServiceMode.deactivate()
      end)

      send_resp(conn, 200, closing_page())
    end
  end

  defp closing_page do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="/assets/js/app.css">
        <title>Service mode closed</title>
      </head>
      <body><main class="closed"><h1>Service mode closed</h1><p>The local service access point is shutting down.</p></main></body>
    </html>
    """
  end
end
