defmodule PlcRemote.TailscaleManagerTest do
  use ExUnit.Case, async: false

  alias PlcRemote.{Configuration, TailscaleManager}

  test "reconfigures a connected proxy when the active PLC interface disappears" do
    original_state = :sys.get_state(TailscaleManager)

    on_exit(fn ->
      :sys.replace_state(TailscaleManager, fn _state -> original_state end)
    end)

    :sys.replace_state(TailscaleManager, fn state ->
      state
      |> put_in([:settings, :machine, :enabled], true)
      |> Map.merge(%{state: :connected, proxy_ifname: "eth0"})
    end)

    send(TailscaleManager, {:machine_interface_changed, nil})

    assert eventually?(fn -> TailscaleManager.status().state != :connected end)
  end

  test "waits for Internet before starting the experimental native client" do
    original = Configuration.get()
    Application.put_env(:plc_remote, :host_connection_status, :disconnected)

    on_exit(fn ->
      Application.delete_env(:plc_remote, :host_connection_status)
      Configuration.restore(original)
    end)

    assert {:ok, _settings} =
             Configuration.update(%{
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit",
               "tailscale_enabled" => "true",
               "tailscale_auth_key" => "tskey-auth-test-only"
             })

    assert eventually?(fn ->
             status = TailscaleManager.status()
             status.state == :waiting_for_network and status.failure_count == 0
           end)
  end

  defp eventually?(predicate, attempts \\ 50)
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
