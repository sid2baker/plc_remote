defmodule PlcRemote.Tailscale.FSMTest do
  use ExUnit.Case, async: false

  alias PlcRemote.{Configuration, Tailscale}
  alias PlcRemote.Events.NetworkChanged

  test "reconnects when the successfully applied PLC interface disappears" do
    original = Configuration.current()

    on_exit(fn -> Configuration.restore(original) end)

    payload = tailscale_payload()
    settings = put_in(payload.settings.machine.enabled, true).settings
    network = %{payload.network | roles: %{payload.network.roles | machine_lan: "eth0"}}

    connected = %{
      payload
      | settings: settings,
        network: network,
        device: :device,
        listener: :listener,
        tailnet_ipv4: "100.64.0.10",
        proxy_ifname: "eth0"
    }

    set_tailscale_state(:connected, connected)
    missing = %{network | roles: %{network.roles | machine_lan: nil}}
    send(PlcRemote.Tailscale.Runtime, %NetworkChanged{status: missing})

    assert eventually?(fn -> Tailscale.status().lifecycle != :connected end)
  end

  test "waits for Internet before starting the native client" do
    original = Configuration.current()
    Application.put_env(:plc_remote, :host_connection_status, :disconnected)

    on_exit(fn ->
      Application.delete_env(:plc_remote, :host_connection_status)
      Configuration.restore(original)
    end)

    assert {:ok, _settings} =
             Configuration.update(%{
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit",
               "tailscale_enabled" => "true"
             })

    assert {:ok, enrollment} =
             PlcRemote.Tailscale.Enrollment.new("tskey-auth-test-only-valid")

    assert {:error, :internet_unavailable} =
             Tailscale.enroll(enrollment, Configuration.current())

    assert Configuration.current().tailscale.enabled
  end

  defp tailscale_payload do
    GenServer.call(PlcRemote.Tailscale.FSM, :state).payload
  end

  defp set_tailscale_state(lifecycle, payload) do
    :sys.replace_state(PlcRemote.Tailscale.FSM, &%{&1 | current: lifecycle, payload: payload})
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
end
