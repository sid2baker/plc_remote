defmodule PlcRemoteWeb.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test

  alias PlcRemote.{Configuration, ServiceMode}
  alias PlcRemoteWeb.Router

  test "renders the responsive settings portal without exposing stored secrets" do
    conn = conn(:get, "/") |> Router.call(Router.init([]))
    service = Configuration.get().service

    assert conn.status == 200
    assert conn.resp_body =~ "PLC Remote Setup"
    assert conn.resp_body =~ "S7 TCP proxy"
    assert conn.resp_body =~ "One-time auth key"
    refute conn.resp_body =~ service.psk
    refute conn.resp_body =~ service.web_secret
    assert get_resp_header(conn, "cache-control") == ["no-store, max-age=0"]
    assert get_resp_header(conn, "content-security-policy") != []
  end

  test "redirects captive portal probes to the setup hostname" do
    conn = conn(:get, "/generate_204") |> Router.call(Router.init([]))

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["http://plc.setup/"]
  end

  test "accepts a CSRF-protected settings form submission" do
    get_conn = conn(:get, "/") |> Router.call(Router.init([]))
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, get_conn.resp_body)

    cookie =
      get_conn
      |> get_resp_header("set-cookie")
      |> hd()
      |> String.split(";", parts: 2)
      |> hd()

    body = URI.encode_query(%{"_csrf_token" => token})

    post_conn =
      :post
      |> conn("/settings", body)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("cookie", cookie)
      |> Router.call(Router.init([]))

    assert post_conn.status == 200
    assert post_conn.resp_body =~ "Settings saved and applied."
  end

  test "reports only non-secret service and Tailscale status" do
    conn = conn(:get, "/api/status") |> Router.call(Router.init([]))
    payload = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert payload["commissioned"] == false
    assert payload["firmware"]["firmware"] == "validated"
    assert payload["recovery"]["consecutive_reboots"] == 0
    assert is_boolean(payload["service_mode"]["active"])
    assert [_, _, _] = payload["network"]["interfaces"]
    assert payload["network"]["roles"]["machine_lan"] == nil
    assert payload["tailscale"]["state"] == "disabled"
    refute conn.resp_body =~ Configuration.service_credentials().psk
  end

  setup do
    on_exit(fn ->
      if ServiceMode.active?(), do: ServiceMode.deactivate()
    end)
  end
end
