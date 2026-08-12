defmodule PlcRemote.HealthTest do
  use ExUnit.Case, async: false

  alias PlcRemote.Health
  alias PlcRemote.Health.Alarm

  alias PlcRemote.Health.Alarms.{
    RemoteAccessExpected,
    RemoteAccessUnavailable,
    TailscaleUnavailable
  }

  test "derives remote access failure without an imperative derived-alarm setter" do
    Alarm.clear(RemoteAccessExpected)
    Alarm.clear(TailscaleUnavailable)
    assert eventually?(fn -> not Health.alarm?(RemoteAccessUnavailable) end)

    Alarm.set(RemoteAccessExpected, :test)
    Alarm.set(TailscaleUnavailable, :test)
    assert eventually?(fn -> Health.alarm?(RemoteAccessUnavailable) end)

    Alarm.clear(TailscaleUnavailable)
    assert eventually?(fn -> not Health.alarm?(RemoteAccessUnavailable) end)
  end

  test "returns a typed health snapshot" do
    assert %PlcRemote.Health.Snapshot{alarms: alarms} = Health.snapshot()
    assert is_list(alarms)
  end

  defp eventually?(predicate, attempts \\ 50)
  defp eventually?(_predicate, 0), do: false

  defp eventually?(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually?(predicate, attempts - 1)
    end
  end
end
