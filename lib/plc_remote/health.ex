defmodule PlcRemote.Health do
  @moduledoc """
  Public read model for current appliance health.

  Health reports persistent conditions. Use subsystem `status/0` APIs to inspect
  lifecycle and runtime progress.
  """

  alias PlcRemote.Health.Alarms.{
    FirmwareCandidateUnvalidated,
    FirmwareValidationFailed,
    InternetUnavailable,
    PlcInterfaceUnavailable,
    RemoteAccessUnavailable,
    TailscaleUnavailable
  }

  alias PlcRemote.Health.Snapshot

  @spec active_alarms() :: [Alarmist.alarm_id()]
  def active_alarms do
    Alarmist.get_alarm_ids(level: :debug)
    |> Enum.filter(&plc_remote_alarm?/1)
    |> Enum.sort()
  end

  @spec alarm?(Alarmist.alarm_id()) :: boolean()
  def alarm?(alarm), do: Alarmist.alarm_state(alarm) == :set

  @spec snapshot() :: Snapshot.t()
  def snapshot do
    alarms = active_alarms()

    %Snapshot{
      internet: availability(InternetUnavailable),
      plc_interface: availability(PlcInterfaceUnavailable),
      tailscale: tailscale_health(),
      remote_access: availability(RemoteAccessUnavailable),
      service_access: PlcRemote.Health.Reporter.service_access(),
      firmware: firmware(),
      alarms: alarms
    }
  end

  defp availability(alarm), do: if(alarm?(alarm), do: :unavailable, else: :available)

  defp tailscale_health do
    settings = PlcRemote.Configuration.current()

    if settings.tailscale.enabled do
      case Alarmist.alarm_state(TailscaleUnavailable) do
        :clear -> :connected
        _set_or_unknown -> :disconnected
      end
    else
      :disabled
    end
  end

  defp firmware do
    cond do
      alarm?(FirmwareValidationFailed) -> :validation_failed
      alarm?(FirmwareCandidateUnvalidated) -> :unvalidated
      true -> :validated
    end
  end

  defp plc_remote_alarm?(alarm_id) do
    alarm_id
    |> Alarmist.alarm_type()
    |> Atom.to_string()
    |> String.starts_with?("Elixir.PlcRemote.Health.Alarms.")
  end
end
