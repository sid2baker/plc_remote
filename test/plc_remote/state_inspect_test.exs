defmodule PlcRemote.StateInspectTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Settings

  test "FSM payload inspection never renders configuration secrets" do
    settings = Settings.defaults(service_psk: "never-render-psk", web_secret: "never-render-web")
    network = network_status()

    states = [
      %PlcRemote.Tailscale.State{
        adapter: PlcRemote.Adapters.Host.Tailscale,
        runtime: self(),
        settings: settings,
        network: network,
        pending_auth_key: "never-render-auth-key"
      },
      %PlcRemote.Service.State{runtime: self(), settings: settings},
      %PlcRemote.Recovery.State{
        runtime: self(),
        settings: settings,
        path: nil,
        consecutive_reboots: 0
      },
      %PlcRemote.Firmware.State{runtime: self(), settings: settings, expectation_path: nil}
    ]

    Enum.each(states, fn state ->
      rendered = inspect(state)
      refute rendered =~ "never-render-psk"
      refute rendered =~ "never-render-web"
      refute rendered =~ "never-render-auth-key"
    end)
  end

  defp network_status do
    %PlcRemote.Network.Status{
      applied: false,
      applied_at: nil,
      connection: :disconnected,
      interfaces: [],
      last_error: nil,
      roles: %{machine_lan: nil, internet_uplink: nil, service_ap: "wlan0", recovery: "usb0"},
      uplink_mode: :disabled
    }
  end
end
