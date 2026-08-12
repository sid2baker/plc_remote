defmodule PlcRemote.Diagnostics do
  @moduledoc "Supported non-secret field diagnostic snapshot."

  @spec snapshot() :: map()
  def snapshot do
    %{
      firmware: PlcRemote.Firmware.status(),
      network: PlcRemote.Network.status(),
      tailscale: PlcRemote.Tailscale.status(),
      service: PlcRemote.Service.status(),
      recovery: PlcRemote.Recovery.status(),
      health: PlcRemote.Health.snapshot()
    }
  end

  @spec explain() :: String.t()
  def explain do
    snapshot = snapshot()

    """
    Firmware: #{snapshot.firmware.lifecycle} (#{snapshot.firmware.validation})
    Network: Internet #{snapshot.health.internet}; PLC interface #{snapshot.health.plc_interface}
    Tailscale: #{snapshot.tailscale.lifecycle}; listener #{snapshot.tailscale.listener}
    Service: #{snapshot.service.lifecycle}
    Recovery: #{snapshot.recovery.lifecycle}; reboot budget #{snapshot.recovery.consecutive_reboots}
    Active alarms: #{format_alarms(snapshot.health.alarms)}
    """
    |> String.trim()
  end

  defp format_alarms([]), do: "none"
  defp format_alarms(alarms), do: Enum.map_join(alarms, ", ", &inspect/1)
end
