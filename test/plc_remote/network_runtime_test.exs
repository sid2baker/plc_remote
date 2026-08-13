defmodule PlcRemote.Network.RuntimeTest do
  use ExUnit.Case, async: false

  alias PlcRemote.Network

  test "exposes typed connectivity and supports explicit recovery operations" do
    original = PlcRemote.Configuration.current()
    on_exit(fn -> PlcRemote.Configuration.restore(original) end)

    assert eventually?(&PlcRemote.Service.active?/0)
    assert eventually?(fn -> PlcRemote.Health.Reporter.service_access() == :active end)
    assert :ok = PlcRemote.Configuration.restore(PlcRemote.Settings.defaults())
    assert :ok = Network.reapply()
    assert {:error, :service_mode_active} = Network.cycle_uplink()

    status = Network.status()
    assert %PlcRemote.Network.Status{} = status
    assert status.connection == :internet
    assert is_nil(status.last_error)
  end

  defp eventually?(predicate, attempts \\ 50)
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
