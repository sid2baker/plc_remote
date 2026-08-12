defmodule PlcRemote.Recovery.SafetyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Recovery.Safety

  @enabled %{auto_reboot: true, max_consecutive_reboots: 2}

  test "permits only validated firmware within the persistent budget" do
    assert :ok = Safety.reboot_allowed?(@enabled, :validated, 0)

    assert {:error, :firmware_unvalidated} =
             Safety.reboot_allowed?(@enabled, :unvalidated, 0)

    assert {:error, :firmware_unvalidated} =
             Safety.reboot_allowed?(@enabled, :unknown, 1)

    assert {:error, :budget_exhausted} = Safety.reboot_allowed?(@enabled, :validated, 2)
  end

  test "operator setting is a hard reboot escape hatch" do
    disabled = %{@enabled | auto_reboot: false}
    assert {:error, :disabled} = Safety.reboot_allowed?(disabled, :validated, 0)
  end
end
