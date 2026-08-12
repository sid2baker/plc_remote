defmodule PlcRemote.Firmware.FSMTest do
  use ExUnit.Case, async: false

  alias PlcRemote.Firmware

  test "refuses to arm OTA rollback evidence without a live tailnet" do
    assert {:error, :tailscale_not_connected} = Firmware.prepare_update()

    status = Firmware.status()
    assert %PlcRemote.Firmware.Status{} = status
    assert status.validation == :validated
    refute status.remote_expected
  end
end
