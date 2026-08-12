defmodule PlcRemote.Service.VerificationTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Health.Snapshot
  alias PlcRemote.Service.Verification
  alias PlcRemote.Settings

  test "requires both Ethernet Internet and an enabled connected tailnet" do
    settings = Settings.defaults()
    health = snapshot(:available, :connected)

    assert {:wait, %{internet: true, tailscale: false}} = Verification.evaluate(health, settings)

    enabled = put_in(settings.tailscale.enabled, true)
    assert :ok = Verification.evaluate(health, enabled)

    assert {:wait, %{internet: false, tailscale: true}} =
             Verification.evaluate(snapshot(:unavailable, :connected), enabled)

    assert {:wait, %{internet: true, tailscale: false}} =
             Verification.evaluate(snapshot(:available, :disconnected), enabled)
  end

  defp snapshot(internet, tailscale) do
    %Snapshot{
      internet: internet,
      plc_interface: :available,
      tailscale: tailscale,
      remote_access: :available,
      service_access: :active,
      firmware: :validated,
      alarms: []
    }
  end
end
