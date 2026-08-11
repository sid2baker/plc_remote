defmodule PlcRemote.ServiceModeTest do
  use ExUnit.Case, async: false

  alias PlcRemote.ServiceMode

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

  setup do
    if ServiceMode.active?(), do: ServiceMode.deactivate()
    on_exit(fn -> if ServiceMode.active?(), do: ServiceMode.deactivate() end)
  end
end
