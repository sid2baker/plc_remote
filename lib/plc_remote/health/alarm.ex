defmodule PlcRemote.Health.Alarm do
  @moduledoc """
  The only imperative boundary for primitive alarms.

  Descriptions may contain structured operational context but must never contain
  credentials. Derived alarms are managed by Alarmist and must not use this API.
  """

  @type id :: Alarmist.alarm_id()
  @type description :: Alarmist.alarm_description()

  @spec set(id(), description()) :: :ok
  def set(id, description \\ nil) do
    :alarm_handler.set_alarm({id, description})
  end

  @spec clear(id()) :: :ok
  def clear(id), do: :alarm_handler.clear_alarm(id)

  @spec report(id(), boolean(), description()) :: :ok
  def report(id, true, description), do: set(id, description)
  def report(id, false, _description), do: clear(id)
end
