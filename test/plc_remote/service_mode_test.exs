defmodule PlcRemote.ServiceModeTest do
  use ExUnit.Case, async: false

  alias PlcRemote.{Configuration, ServiceMode, Settings, TailscaleManager}

  test "starts and stops the local service web server" do
    refute ServiceMode.active?()
    assert :ok = ServiceMode.activate()
    assert ServiceMode.active?()

    status = ServiceMode.status()
    assert status.ssid == "PLC-Remote-HOST"
    assert status.mode == :recovery
    assert status.secured
    assert status.address == "192.168.50.1"
    assert status.expires_in_seconds > 0

    assert :ok = ServiceMode.deactivate()
    refute ServiceMode.active?()
  end

  test "discards onsite settings that are not verified before service exit" do
    original = PlcRemote.Configuration.get()
    on_exit(fn -> PlcRemote.Configuration.restore(original) end)

    :ok = PlcRemote.Configuration.restore(%{original | commissioned: true})
    restart_service_boundary()
    assert :ok = ServiceMode.activate()

    replacement_domain = if original.uplink.regulatory_domain == "US", do: "DE", else: "US"

    assert {:ok, _settings} =
             PlcRemote.Configuration.update(%{"regulatory_domain" => replacement_domain})

    assert eventually?(fn ->
             :sys.get_state(ServiceMode).settings.uplink.regulatory_domain == replacement_domain
           end)

    assert :ok = ServiceMode.deactivate()

    assert PlcRemote.Configuration.get().uplink.regulatory_domain ==
             original.uplink.regulatory_domain
  end

  test "commissions after Internet and Tailscale pass without requiring PLC settings" do
    original = Configuration.get()
    on_exit(fn -> Configuration.restore(original) end)

    assert {:ok, configured, nil} =
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

    assert eventually?(fn -> ServiceMode.status().mode == :automatic end)
    assert eventually?(fn -> TailscaleManager.status().state == :error end)

    :sys.replace_state(TailscaleManager, fn state ->
      %{state | state: :connected, tailnet_ipv4: "100.64.0.10", reason: nil}
    end)

    assert {:ok, :verifying} = ServiceMode.finish_commissioning()

    assert eventually?(fn ->
             settings = Configuration.get()
             settings.commissioned and not settings.machine.enabled and not ServiceMode.active?()
           end)
  end

  test "keeps the setup AP active when final verification times out" do
    Application.put_env(:plc_remote, :auto_commissioning, true)
    Application.put_env(:plc_remote, :commissioning_verification_check_ms, 10)
    Application.put_env(:plc_remote, :commissioning_verification_timeout_ms, 50)
    restart_service_boundary()

    assert eventually?(fn -> ServiceMode.status().mode == :automatic end)

    :sys.replace_state(TailscaleManager, fn state ->
      %{state | state: :error, tailnet_ipv4: nil, reason: "test outage"}
    end)

    assert {:ok, :verifying} = ServiceMode.finish_commissioning()

    assert eventually?(fn ->
             status = ServiceMode.status()
             status.mode == :verifying and status.active
           end)

    assert eventually?(fn ->
             status = ServiceMode.status()
             status.mode == :automatic and status.active and status.verification.state == :failed
           end)
  end

  setup do
    if ServiceMode.active?(), do: ServiceMode.deactivate()

    on_exit(fn ->
      Application.put_env(:plc_remote, :auto_commissioning, false)
      Application.delete_env(:plc_remote, :commissioning_verification_check_ms)
      Application.delete_env(:plc_remote, :commissioning_verification_timeout_ms)
      restart_service_boundary()
      if ServiceMode.active?(), do: ServiceMode.deactivate()
    end)
  end

  defp restart_service_boundary do
    :ok = Supervisor.terminate_child(PlcRemote.Supervisor, PlcRemote.ServiceMode.Supervisor)
    {:ok, _pid} = Supervisor.restart_child(PlcRemote.Supervisor, PlcRemote.ServiceMode.Supervisor)
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
