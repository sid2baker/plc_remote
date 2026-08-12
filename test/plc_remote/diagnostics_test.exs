defmodule PlcRemote.DiagnosticsTest do
  use ExUnit.Case, async: false

  test "returns typed non-secret subsystem and health read models" do
    snapshot = PlcRemote.Diagnostics.snapshot()

    assert %PlcRemote.Firmware.Status{} = snapshot.firmware
    assert %PlcRemote.Network.Status{} = snapshot.network
    assert %PlcRemote.Panel.Status{} = snapshot.panel
    assert %PlcRemote.Tailscale.Status{} = snapshot.tailscale
    assert %PlcRemote.Service.Status{} = snapshot.service
    assert %PlcRemote.Recovery.Status{} = snapshot.recovery
    assert %PlcRemote.Health.Snapshot{} = snapshot.health

    rendered = inspect(snapshot)
    refute rendered =~ PlcRemote.Configuration.current().service.psk
    refute rendered =~ PlcRemote.Configuration.current().service.web_secret
  end
end
