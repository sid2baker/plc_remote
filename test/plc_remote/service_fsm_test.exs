defmodule PlcRemote.Service.FSMTest do
  use ExUnit.Case, async: false

  alias PlcRemote.Service

  test "unavailable IN1 keeps the protected service WLAN active" do
    restart_service_boundary()

    assert eventually?(fn -> Service.status().active end)
    status = Service.status()
    assert status.lifecycle == :active
    assert status.secured
    assert status.gpio_asserted == :unknown
    assert status.ssid == "PLC-Remote-HOST"
  end

  test "only a confirmed high input disables the service WLAN" do
    set_gpio(%PlcRemote.Service.GPIOState{handle: self(), asserted?: false})
    Service.recheck()
    assert eventually?(fn -> not Service.status().active end)

    set_gpio(%PlcRemote.Service.GPIOState{handle: self(), asserted?: true})
    Service.recheck()
    assert eventually?(&Service.active?/0)
  end

  defp set_gpio(gpio) do
    :sys.replace_state(PlcRemote.Service.FSM, fn state ->
      %{state | payload: %{state.payload | gpio: gpio}}
    end)
  end

  defp restart_service_boundary do
    :ok = Supervisor.terminate_child(PlcRemote.Supervisor, PlcRemote.Service.Supervisor)
    {:ok, _pid} = Supervisor.restart_child(PlcRemote.Supervisor, PlcRemote.Service.Supervisor)
    :ok
  end

  defp eventually?(predicate, attempts \\ 200)
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
