defmodule PlcRemote.FirmwareValidatorTest do
  use ExUnit.Case, async: false

  alias PlcRemote.FirmwareValidator

  test "refuses to arm OTA rollback evidence without a live tailnet" do
    assert {:error, :tailscale_not_connected} = FirmwareValidator.prepare_for_update()

    status = FirmwareValidator.status()
    assert status.firmware == :validated
    refute status.remote_expected
  end
end
