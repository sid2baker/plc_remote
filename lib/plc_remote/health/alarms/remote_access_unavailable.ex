defmodule PlcRemote.Health.Alarms.RemoteAccessUnavailable do
  @moduledoc "Commissioned, enabled remote access is currently unavailable."

  use Alarmist.Alarm, level: :error

  alias PlcRemote.Health.Alarms.{RemoteAccessExpected, TailscaleUnavailable}

  alarm_if do
    RemoteAccessExpected and TailscaleUnavailable
  end
end
