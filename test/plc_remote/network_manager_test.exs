defmodule PlcRemote.NetworkManagerTest do
  use ExUnit.Case, async: false

  alias PlcRemote.{NetworkManager, ServiceMode}

  test "exposes connectivity and supports explicit recovery operations" do
    original = PlcRemote.Configuration.get()
    on_exit(fn -> PlcRemote.Configuration.restore(original) end)

    refute ServiceMode.active?()
    assert :ok = PlcRemote.Configuration.restore(PlcRemote.Settings.defaults())
    assert :ok = NetworkManager.reapply()
    assert {:error, :internet_uplink_unassigned} = NetworkManager.cycle_uplink()

    status = NetworkManager.status()
    assert status.connection == :internet
    assert is_nil(status.last_error)
  end

  setup do
    if ServiceMode.active?(), do: ServiceMode.deactivate()
    :ok
  end
end
