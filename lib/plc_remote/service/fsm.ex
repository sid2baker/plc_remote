defmodule PlcRemote.Service.FSM do
  @moduledoc "Lifecycle for the service-switch controlled WPA2 access point."

  @fsm """
  [*] --> inactive : boot
  inactive --> active : enable
  inactive --> fault : failed
  active --> inactive : disable
  active --> fault : failed
  fault --> active : enable
  fault --> inactive : disable
  inactive --> inactive : refresh
  active --> active : refresh
  fault --> fault : refresh
  inactive --> [*] : shutdown
  active --> [*] : shutdown
  fault --> [*] : shutdown
  """

  use Finitomata,
    fsm: @fsm,
    syntax: :state_diagram,
    telemetria_levels: :none,
    impl_for: :none

  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.ServiceAPUnavailable
  alias PlcRemote.Service.State

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, %State{} = state) do
    Alarm.clear(ServiceAPUnavailable)
    {:ok, :inactive, state}
  end

  def on_transition(current, :enable, _event_payload, %State{} = state)
      when current in [:inactive, :fault] do
    case PlcRemote.Service.Actions.enter_access_point(state) do
      {:ok, state} ->
        Alarm.clear(ServiceAPUnavailable)
        {:ok, :active, %{state | last_error: nil}}

      {:error, error, state} ->
        Alarm.set(ServiceAPUnavailable, error)
        {:ok, :fault, %{state | last_error: error}}
    end
  end

  def on_transition(:active, :disable, _event_payload, %State{} = state) do
    state = PlcRemote.Service.Actions.leave_access_point(state)
    Alarm.clear(ServiceAPUnavailable)
    {:ok, :inactive, %{state | last_error: nil}}
  end

  def on_transition(:fault, :disable, _event_payload, %State{} = state) do
    state = PlcRemote.Service.Actions.leave_access_point(state)
    Alarm.clear(ServiceAPUnavailable)
    {:ok, :inactive, %{state | last_error: nil}}
  end

  def on_transition(:inactive, :disable, _event_payload, %State{} = state),
    do: {:ok, :inactive, state}

  def on_transition(:active, :failed, error, %State{} = state) do
    state = PlcRemote.Service.Actions.leave_access_point(state)
    Alarm.set(ServiceAPUnavailable, error)
    {:ok, :fault, %{state | last_error: error}}
  end

  def on_transition(current, :refresh, %State{} = updated, %State{}),
    do: {:ok, current, updated}

  def on_transition(current, event, _event_payload, _state),
    do: {:error, {:invalid_service_transition, current, event}}

  @impl Finitomata
  def on_enter(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_exit(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_failure(_event, _payload, _state), do: :ok

  @impl Finitomata
  def on_terminate(%Finitomata.State{payload: %State{} = state}) do
    _state = PlcRemote.Service.Actions.leave_access_point(state)
    Alarm.clear(ServiceAPUnavailable)
    :ok
  end
end
