defmodule PlcRemoteWeb.RouterTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]
  import ExUnit.CaptureLog

  alias PlcRemote.Configuration
  alias PlcRemoteWeb.Endpoint

  @endpoint Endpoint

  test "renders one live configuration page" do
    {:ok, view, html} = live(build_conn(), "/")
    service = Configuration.current().service

    assert html =~ "Gateway status and configuration"
    assert html =~ "Detected network devices"
    assert html =~ "Join the Tailscale network"
    assert has_element?(view, "#detected-devices")
    assert has_element?(view, "form[phx-submit=save-network]")
    assert has_element?(view, "form[phx-submit=save-plc]")
    assert has_element?(view, "form[phx-submit=enroll-tailscale]")
    refute html =~ "STEP 1"
    refute html =~ "Finish setup"
    refute html =~ service.psk
    refute html =~ service.web_secret
  end

  test "shows detected Ethernet controllers and saves DHCP Internet settings" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "eth0"
    assert html =~ "eth1"

    assert has_element?(
             view,
             "select[name='settings[ethernet_interface_hw_path]'] option[selected][value='/devices/host/usb-2.5-gigabit']"
           )

    assert has_element?(
             view,
             "select[name='settings[machine_interface_hw_path]'] option[selected][value='/devices/host/native-gigabit']"
           )

    html =
      view
      |> form("form[phx-submit=save-network]",
        settings: %{
          "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit",
          "ethernet_method" => "dhcp"
        }
      )
      |> render_submit()

    assert Configuration.current().uplink.mode == :ethernet
    assert html =~ "Network settings saved"
  end

  test "missing and implausible Tailscale keys are rejected without enabling Tailscale" do
    {:ok, view, _html} = live(build_conn(), "/")

    html =
      view
      |> form("form[phx-submit=enroll-tailscale]", settings: %{"tailscale_auth_key" => ""})
      |> render_submit()

    assert html =~ "Enter a Tailscale auth key"
    refute Configuration.current().tailscale.enabled

    html =
      view
      |> form("form[phx-submit=enroll-tailscale]",
        settings: %{"tailscale_auth_key" => "wrong"}
      )
      |> render_submit()

    assert html =~ "auth key format is not valid"
    refute Configuration.current().tailscale.enabled
  end

  test "failed candidate enrollment leaves settings unchanged and accepts another key" do
    original = Configuration.current()

    assert {:ok, _settings} =
             Configuration.update(%{
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit"
             })

    {:ok, view, _html} = live(build_conn(), "/")

    log =
      capture_log(fn ->
        view
        |> form("form[phx-submit=enroll-tailscale]",
          settings: %{"tailscale_auth_key" => "tskey-auth-rejected-valid"}
        )
        |> render_submit()
      end)

    refute log =~ "tskey-auth-rejected-valid"
    assert eventually?(fn -> render(view) =~ "Tailscale rejected the key" end)
    refute Configuration.current().tailscale.enabled
    assert has_element?(view, "input[name='settings[tailscale_auth_key]']")

    Configuration.restore(original)
  end

  test "successful candidate enrollment is persisted only after validation" do
    original = Configuration.current()
    Application.put_env(:plc_remote, :host_tailscale_enrollment_result, {:ok, {100, 64, 0, 9}})

    on_exit(fn ->
      Application.delete_env(:plc_remote, :host_tailscale_enrollment_result)
      Configuration.restore(original)
    end)

    assert {:ok, _settings} =
             Configuration.update(%{
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit"
             })

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form("form[phx-submit=enroll-tailscale]",
      settings: %{"tailscale_auth_key" => "tskey-auth-accepted-valid"}
    )
    |> render_submit()

    assert eventually?(fn ->
             render(view) =~ "Tailscale joined successfully at 100.64.0.9"
           end)

    assert Configuration.current().tailscale.enabled
  end

  test "filters one-time credentials from rendered output and logs" do
    {:ok, view, _html} = live(build_conn(), "/")
    secret = "tskey-auth-never-log-this-valid"

    log =
      capture_log(fn ->
        html =
          view
          |> form("form[phx-submit=enroll-tailscale]",
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
  end

  test "does not expose a browser command that can disable service access" do
    conn = post(build_conn(), "/service/exit")
    assert conn.status == 404
  end

  setup do
    original = Configuration.current()
    on_exit(fn -> Configuration.restore(original) end)
    :ok
  end

  defp eventually?(predicate, attempts \\ 100)
  defp eventually?(_predicate, 0), do: false

  defp eventually?(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually?(predicate, attempts - 1)
    end
  end
end
