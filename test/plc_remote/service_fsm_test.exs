defmodule PlcRemote.Service.FSMTest do
  use ExUnit.Case, async: false

  alias PlcRemote.{Configuration, Service, Settings, Tailscale}

  test "starts and stops protected local service access" do
    refute Service.active?()
    assert :ok = Service.activate()
    assert Service.active?()

    status = Service.status()
    assert %PlcRemote.Service.Status{} = status
    assert status.ssid == "PLC-Remote-HOST"
    assert status.lifecycle == :recovery
    assert status.secured
    assert status.address == "192.168.50.1"
    assert status.expires_in_seconds > 0

    assert :ok = Service.deactivate()
    refute Service.active?()
  end

  test "discards onsite settings that are not verified before service exit" do
    original = Configuration.current()
    on_exit(fn -> Configuration.restore(original) end)

    :ok = Configuration.restore(%{original | commissioned: true})
    restart_service_boundary()
    assert :ok = Service.activate()

    replacement_domain = if original.uplink.regulatory_domain == "US", do: "DE", else: "US"
    assert {:ok, _settings} = Configuration.update(%{"regulatory_domain" => replacement_domain})

    assert eventually?(fn ->
             service_payload().settings.uplink.regulatory_domain == replacement_domain
           end)

    assert :ok = Service.deactivate()
    assert Configuration.current().uplink.regulatory_domain == original.uplink.regulatory_domain
  end

  test "commissions after Health reports Internet and Tailscale without PLC provisioning" do
    original = Configuration.current()
    on_exit(fn -> Configuration.restore(original) end)

    assert {:ok, configured} =
             Settings.update(original, %{
               "machine_enabled" => "false",
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/host/usb-2.5-gigabit",
               "tailscale_enabled" => "true"
             })

    :ok = Configuration.restore(%{configured | commissioned: false})
    Application.put_env(:plc_remote, :auto_commissioning, true)
    Application.put_env(:plc_remote, :commissioning_verification_check_ms, 10)
    Application.put_env(:plc_remote, :commissioning_verification_timeout_ms, 500)
    restart_service_boundary()

    assert eventually?(fn -> Service.status().lifecycle == :automatic end)
    set_tailscale_connected()
    assert {:ok, :verifying} = Service.finish_commissioning()

    assert eventually?(fn ->
             settings = Configuration.current()
             settings.commissioned and not settings.machine.enabled and not Service.active?()
           end)
  end

  test "keeps setup AP active when final verification times out" do
    Application.put_env(:plc_remote, :auto_commissioning, true)
    Application.put_env(:plc_remote, :commissioning_verification_check_ms, 10)
    Application.put_env(:plc_remote, :commissioning_verification_timeout_ms, 50)
    Application.put_env(:plc_remote, :host_connection_status, :disconnected)
    :ok = PlcRemote.Network.reapply()
    PlcRemote.Health.Alarm.set(PlcRemote.Health.Alarms.InternetUnavailable, :test_outage)
    PlcRemote.Health.Alarm.set(PlcRemote.Health.Alarms.TailscaleUnavailable, :test_outage)
    restart_service_boundary()

    assert eventually?(fn -> Service.status().lifecycle == :automatic end)
    assert {:ok, :verifying} = Service.finish_commissioning()

    assert eventually?(fn -> Service.status().lifecycle == :verifying_automatic end)

    assert eventually?(fn ->
             status = Service.status()

             status.lifecycle == :automatic and status.active and
               status.verification.state == :failed
           end)
  end

  setup do
    if Service.active?(), do: Service.deactivate()

    on_exit(fn ->
      Application.put_env(:plc_remote, :auto_commissioning, false)
      Application.delete_env(:plc_remote, :commissioning_verification_check_ms)
      Application.delete_env(:plc_remote, :commissioning_verification_timeout_ms)
      Application.delete_env(:plc_remote, :host_connection_status)
      restart_service_boundary()
      if Service.active?(), do: Service.deactivate()
    end)
  end

  defp service_payload, do: GenServer.call(PlcRemote.Service.FSM, :state).payload

  defp set_tailscale_connected do
    :sys.replace_state(PlcRemote.Tailscale.FSM, fn state ->
      payload = %{
        state.payload
        | tailnet_ipv4: "100.64.0.10",
          connected_since: System.monotonic_time(:millisecond),
          last_error: nil
      }

      %{state | current: :connected, payload: payload}
    end)

    PlcRemote.Health.Alarm.clear(PlcRemote.Health.Alarms.TailscaleUnavailable)
    assert Tailscale.status().lifecycle == :connected
  end

  defp restart_service_boundary do
    :ok = Supervisor.terminate_child(PlcRemote.Supervisor, PlcRemote.Service.Supervisor)
    {:ok, _pid} = Supervisor.restart_child(PlcRemote.Supervisor, PlcRemote.Service.Supervisor)
    :ok
  end

  defp eventually?(predicate, attempts \\ 300)
  defp eventually?(_predicate, 0), do: false

  defp eventually?(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(5)
      eventually?(predicate, attempts - 1)
    end
  end
end
