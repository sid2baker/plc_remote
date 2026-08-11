defmodule PlcRemote.NetworkManagerTest do
  use ExUnit.Case, async: false

  alias PlcRemote.{NetworkManager, ServiceMode}

  test "exposes connectivity and supports explicit recovery operations" do
    refute ServiceMode.active?()
    assert :ok = NetworkManager.reapply()
    assert :ok = NetworkManager.cycle_uplinks()

    status = NetworkManager.status()
    assert status.connection == :internet
    assert is_nil(status.last_error)
  end

  setup do
    if ServiceMode.active?(), do: ServiceMode.deactivate()
    :ok
  end
end
