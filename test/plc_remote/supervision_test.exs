defmodule PlcRemote.SupervisionTest do
  use ExUnit.Case, async: false

  test "root starts Health and lifecycle runtimes after Configuration" do
    assert is_pid(Process.whereis(PlcRemote.Health.Reporter))
    assert is_pid(Process.whereis(PlcRemote.Network.Runtime))
    assert is_pid(Process.whereis(PlcRemote.Panel.Runtime))
    assert is_pid(Process.whereis(PlcRemote.Recovery.Runtime))
    assert is_pid(Process.whereis(PlcRemote.Firmware.Runtime))
  end

  test "Tailscale boundary restarts runtime and task supervisors together" do
    previous = tailscale_processes()
    Process.exit(previous.runtime, :kill)

    assert eventually(fn ->
             current = tailscale_processes()

             Enum.all?(Map.keys(previous), fn key ->
               is_pid(current[key]) and current[key] != previous[key]
             end)
           end)
  end

  test "service boundary restores protected AP intent after runtime crash" do
    original = PlcRemote.Configuration.current()

    on_exit(fn ->
      if PlcRemote.Service.active?(), do: PlcRemote.Service.deactivate()
      PlcRemote.Configuration.restore(original)
    end)

    :ok = PlcRemote.Configuration.restore(%{original | commissioned: true})
    assert :ok = PlcRemote.Service.activate()

    previous_service = Process.whereis(PlcRemote.Service.Runtime)
    previous_web = Process.whereis(PlcRemote.Service.WebSupervisor)
    previous_runtime = Process.whereis(PlcRemote.Service.WebRuntimeSupervisor)
    Process.exit(previous_service, :kill)

    assert eventually(fn ->
             service = Process.whereis(PlcRemote.Service.Runtime)
             web = Process.whereis(PlcRemote.Service.WebSupervisor)
             runtime = Process.whereis(PlcRemote.Service.WebRuntimeSupervisor)

             status =
               if is_pid(service) do
                 try do
                   PlcRemote.Service.status()
                 catch
                   :exit, _reason -> nil
                 end
               end

             is_pid(service) and is_pid(web) and is_pid(runtime) and service != previous_service and
               web != previous_web and runtime != previous_runtime and not is_nil(status) and
               status.active and status.lifecycle == :recovery
           end)
  end

  defp tailscale_processes do
    %{
      connection_tasks: Process.whereis(PlcRemote.Tailscale.ConnectionSupervisor),
      runtime: Process.whereis(PlcRemote.Tailscale.Runtime),
      proxy_tasks: Process.whereis(PlcRemote.Tailscale.SessionSupervisor)
    }
  end

  defp eventually(predicate, attempts \\ 100)
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
