defmodule PlcRemoteWeb.RouterTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]
  import ExUnit.CaptureLog

  alias PlcRemote.{Configuration, ServiceMode, Settings}
  alias PlcRemoteWeb.Endpoint

  @endpoint Endpoint

  test "renders an Ethernet-only commissioning wizard without stored secrets" do
    {:ok, view, html} = live(build_conn(), "/")
    service = Configuration.get().service

    assert html =~ "Connect this gateway in three steps"
    assert html =~ "Connect one Ethernet port"
    assert has_element?(view, "input[name='settings[uplink_mode]'][value='ethernet']")
    assert has_element?(view, "select[name='settings[ethernet_interface_hw_path]']")
    refute html =~ "Wi-Fi network"
    refute html =~ "wifi_ssid"
    refute html =~ "wifi_psk"
    refute html =~ "Rescan networks"
    refute html =~ "settings[plc_address]"
    refute html =~ "settings[plc_destination_port]"
    refute html =~ service.psk
    refute html =~ service.web_secret
  end

  test "uses DHCP by default and tests Ethernet before continuing" do
    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "details[data-visible-when='ethernet_method:static'][hidden]")

    html =
      view
      |> form("form[phx-submit=save-network]",
        settings: %{
          "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit",
          "ethernet_method" => "dhcp"
        }
      )
      |> render_submit()

    assert Configuration.get().uplink.mode == :ethernet
    assert html =~ "Internet connection works"
    assert has_element?(view, "a", "Continue to Tailscale")
  end

  test "shows the Tailscale connection result directly on the auth-key step" do
    assert {:ok, _settings} =
             Configuration.update(%{
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit"
             })

    {:ok, view, _html} = live(build_conn(), "/?step=tailscale")
    assert has_element?(view, "input[name='settings[tailscale_auth_key]']")
    refute has_element?(view, "input[name='settings[plc_destination_port]']")
    refute has_element?(view, "input[name='settings[plc_address]']")

    view
    |> form("form[phx-submit=save-tailscale]",
      settings: %{"tailscale_auth_key" => "tskey-auth-test-only"}
    )
    |> render_submit()

    assert eventually?(fn -> render(view) =~ "Tailscale could not connect" end)
    assert has_element?(view, "button", "Connect Tailscale")
  end

  test "failed final verification returns the live page while keeping the AP active" do
    original = Configuration.get()
    Application.put_env(:plc_remote, :auto_commissioning, true)
    Application.put_env(:plc_remote, :commissioning_verification_check_ms, 10)
    Application.put_env(:plc_remote, :commissioning_verification_timeout_ms, 50)

    on_exit(fn ->
      Application.put_env(:plc_remote, :auto_commissioning, false)
      Application.delete_env(:plc_remote, :commissioning_verification_check_ms)
      Application.delete_env(:plc_remote, :commissioning_verification_timeout_ms)
      Configuration.restore(original)
    end)

    assert {:ok, candidate, nil} =
             Settings.update(original, %{
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit",
               "tailscale_enabled" => "true"
             })

    assert :ok = ServiceMode.deactivate()
    assert :ok = Configuration.restore(%{candidate | commissioned: false})
    restart_service_boundary()
    assert eventually?(fn -> ServiceMode.status().mode == :automatic end)

    {:ok, view, _html} = live(build_conn(), "/?step=verify")
    view |> element("button[phx-click='finish-commissioning']") |> render_click()
    assert has_element?(view, "#commissioning-handoff")

    assert eventually?(fn ->
             has_element?(view, "#final-verification-failed") and
               not has_element?(view, "#commissioning-handoff")
           end)

    assert ServiceMode.status().active
  end

  test "filters one-time credentials from rendered output and LiveView logs" do
    {:ok, view, _html} = live(build_conn(), "/?step=tailscale")
    secret = "tskey-auth-never-log-this"

    log =
      capture_log(fn ->
        html =
          view
          |> form("form[phx-submit=save-tailscale]",
            settings: %{"tailscale_auth_key" => secret}
          )
          |> render_submit()

        refute html =~ secret
      end)

    refute log =~ secret
  end

  test "redirects captive portal probes to the stable setup hostname" do
    conn = get(build_conn(), "/generate_204")

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["http://plc.setup/"]
    assert get_resp_header(conn, "cache-control") == ["no-store, max-age=0"]
  end

  defp restart_service_boundary do
    :ok = Supervisor.terminate_child(PlcRemote.Supervisor, PlcRemote.ServiceMode.Supervisor)
    {:ok, _pid} = Supervisor.restart_child(PlcRemote.Supervisor, PlcRemote.ServiceMode.Supervisor)
    :ok
  end

  defp eventually?(predicate, attempts \\ 100)
  defp eventually?(_predicate, 0), do: false

  defp eventually?(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(20)
      eventually?(predicate, attempts - 1)
    end
  end

  setup do
    Application.put_env(:plc_remote, :auto_commissioning, false)
    restart_service_boundary()
    assert :ok = ServiceMode.activate()

    on_exit(fn ->
      Application.put_env(:plc_remote, :auto_commissioning, false)
      restart_service_boundary()
      if ServiceMode.active?(), do: ServiceMode.deactivate()
    end)
  end
end
