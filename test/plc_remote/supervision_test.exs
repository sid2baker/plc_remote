defmodule PlcRemote.SupervisionTest do
  use ExUnit.Case, async: false

  test "root starts recovery and firmware validation after operational boundaries" do
    assert is_pid(Process.whereis(PlcRemote.RecoveryManager))
    assert is_pid(Process.whereis(PlcRemote.FirmwareValidator))
  end

  test "Tailscale boundary restarts the manager and all task supervisors together" do
    previous = tailscale_processes()
    Process.exit(previous.manager, :kill)

    assert eventually(fn ->
             current = tailscale_processes()

             Enum.all?(Map.keys(previous), fn key ->
               is_pid(current[key]) and current[key] != previous[key]
             end)
           end)
  end

  test "service boundary restores an active onsite AP after a manager crash" do
    original = PlcRemote.Configuration.get()

    on_exit(fn ->
      if service_active?(), do: PlcRemote.ServiceMode.deactivate()
      PlcRemote.Configuration.restore(original)
    end)

    :ok = PlcRemote.Configuration.restore(%{original | commissioned: true})
    assert :ok = PlcRemote.ServiceMode.activate()

    previous_service = Process.whereis(PlcRemote.ServiceMode)
    previous_web = Process.whereis(PlcRemote.ServiceMode.WebSupervisor)
    previous_runtime = Process.whereis(PlcRemote.ServiceMode.WebRuntimeSupervisor)
    Process.exit(previous_service, :kill)

    assert eventually(fn ->
             service = Process.whereis(PlcRemote.ServiceMode)
             web = Process.whereis(PlcRemote.ServiceMode.WebSupervisor)
             runtime = Process.whereis(PlcRemote.ServiceMode.WebRuntimeSupervisor)
             status = if is_pid(service), do: service_status(), else: %{}

             is_pid(service) and is_pid(web) and is_pid(runtime) and service != previous_service and
               web != previous_web and runtime != previous_runtime and status[:active] and
               status[:mode] == :recovery
           end)
  end

  defp service_active? do
    PlcRemote.ServiceMode.active?()
  catch
    :exit, _reason -> false
  end

  defp service_status do
    PlcRemote.ServiceMode.status()
  catch
    :exit, _reason -> %{}
  end

  defp tailscale_processes do
    %{
      connection_tasks: Process.whereis(PlcRemote.TailscaleConnectionTaskSupervisor),
      manager: Process.whereis(PlcRemote.TailscaleManager),
      proxy_tasks: Process.whereis(PlcRemote.TailscaleSessionTaskSupervisor)
    }
  end

  defp eventually(predicate, attempts \\ 50)

  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(20)
      eventually(predicate, attempts - 1)
    end
  end
end
