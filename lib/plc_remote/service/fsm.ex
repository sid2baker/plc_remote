defmodule PlcRemote.Service.FSM do
  @moduledoc "Explicit setup/recovery AP and final-verification lifecycle."

  @fsm """
  [*] --> inactive : boot
  inactive --> automatic : commissioning_required
  inactive --> recovery : activate_requested
  automatic --> verifying_automatic : finish_requested
  recovery --> verifying_recovery : finish_requested
  automatic --> inactive : deactivate_requested
  recovery --> inactive : deactivate_requested
  verifying_automatic --> inactive : verification_succeeded
  verifying_automatic --> automatic : verification_failed
  verifying_recovery --> inactive : verification_succeeded
  verifying_recovery --> recovery : verification_failed
  inactive --> inactive : refresh
  automatic --> automatic : refresh
  recovery --> recovery : refresh
  verifying_automatic --> verifying_automatic : refresh
  verifying_recovery --> verifying_recovery : refresh
  fault --> fault : refresh
  automatic --> fault : portal_stopped
  recovery --> fault : portal_stopped
  verifying_automatic --> fault : portal_stopped
  verifying_recovery --> fault : portal_stopped
  fault --> automatic : retry_automatic
  fault --> recovery : retry_recovery
  fault --> inactive : deactivate_requested
  inactive --> [*] : shutdown
  automatic --> [*] : shutdown
  recovery --> [*] : shutdown
  verifying_automatic --> [*] : shutdown
  verifying_recovery --> [*] : shutdown
  fault --> [*] : shutdown
  """

  use Finitomata,
    fsm: @fsm,
    syntax: :state_diagram,
    telemetria_levels: :none,
    impl_for: :none

  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.ServiceAPUnavailable
  alias PlcRemote.Service.{Actions, State, Verification}

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, %State{} = state) do
    Alarm.clear(ServiceAPUnavailable)
    {:ok, :inactive, state}
  end

  def on_transition(:inactive, :commissioning_required, _event_payload, %State{} = state) do
    start_access(state, :automatic, :automatic)
  end

  def on_transition(:inactive, :activate_requested, _event_payload, %State{} = state) do
    start_access(state, :recovery, :recovery)
  end

  def on_transition(:fault, :retry_automatic, _event_payload, %State{} = state) do
    start_access(state, :automatic, :automatic)
  end

  def on_transition(:fault, :retry_recovery, _event_payload, %State{} = state) do
    start_access(state, :recovery, :recovery)
  end

  def on_transition(:automatic, :finish_requested, _event_payload, %State{} = state) do
    {:ok, :verifying_automatic,
     %{state | verification: Verification.starting(), verification_deadline: nil}}
  end

  def on_transition(:recovery, :finish_requested, _event_payload, %State{} = state) do
    {:ok, :verifying_recovery,
     %{state | verification: Verification.starting(), verification_deadline: nil}}
  end

  def on_transition(verifying, :verification_succeeded, checks, %State{} = state)
      when verifying in [:verifying_automatic, :verifying_recovery] do
    with :ok <- commit_verification(verifying) do
      state = Actions.leave_access_point(state)
      Actions.clear_intent()
      Alarm.clear(ServiceAPUnavailable)

      {:ok, :inactive,
       %{
         state
         | settings: PlcRemote.Configuration.current(),
           verification: Verification.passed(checks),
           verification_deadline: nil,
           last_error: nil
       }}
    end
  end

  def on_transition(verifying, :verification_failed, {checks, reason}, %State{} = state)
      when verifying in [:verifying_automatic, :verifying_recovery] do
    destination = if verifying == :verifying_automatic, do: :automatic, else: :recovery

    case rollback_failed_verification(verifying) do
      :ok ->
        {:ok, destination,
         %{
           state
           | settings: PlcRemote.Configuration.current(),
             verification: Verification.failed(checks, reason),
             verification_deadline: nil
         }}

      {:error, rollback_reason} ->
        fail_closed(state, {:verification_rollback_failed, rollback_reason})
    end
  end

  def on_transition(current, :deactivate_requested, _event_payload, %State{} = state)
      when current in [:automatic, :recovery, :fault] do
    if current == :recovery, do: Actions.rollback_transaction()
    state = Actions.leave_access_point(state)
    Actions.clear_intent()
    Alarm.clear(ServiceAPUnavailable)
    {:ok, :inactive, %{state | settings: PlcRemote.Configuration.current()}}
  end

  def on_transition(current, :portal_stopped, error, %State{} = state)
      when current in [:automatic, :recovery, :verifying_automatic, :verifying_recovery] do
    if current in [:recovery, :verifying_recovery], do: Actions.rollback_transaction()
    state = Actions.leave_access_point(state)
    Alarm.set(ServiceAPUnavailable, error)
    {:ok, :fault, %{state | last_error: error, settings: PlcRemote.Configuration.current()}}
  end

  def on_transition(current, :refresh, %State{} = updated, %State{}) do
    {:ok, current, updated}
  end

  def on_transition(current, event, _event_payload, _state) do
    {:error, {:invalid_service_transition, current, event}}
  end

  @impl Finitomata
  def on_enter(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_exit(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_failure(_event, _payload, _state), do: :ok

  @impl Finitomata
  def on_terminate(%Finitomata.State{payload: %State{} = state}) do
    _state = Actions.leave_access_point(state)
    Alarm.clear(ServiceAPUnavailable)
    :ok
  end

  defp start_access(state, :recovery = mode, destination) do
    case Actions.begin_transaction() do
      :ok ->
        start_access_point(state, mode, destination)

      {:error, reason} ->
        error = %PlcRemote.Error{
          subsystem: :service,
          operation: :begin_transaction,
          reason: reason
        }

        Alarm.set(ServiceAPUnavailable, error)
        {:ok, :fault, %{state | last_error: error}}
    end
  end

  defp start_access(state, :automatic = mode, destination) do
    start_access_point(state, mode, destination)
  end

  defp start_access_point(state, mode, destination) do
    case Actions.enter_access_point(state, mode) do
      {:ok, state} ->
        Alarm.clear(ServiceAPUnavailable)
        {:ok, destination, %{state | last_error: nil}}

      {:error, error, state} ->
        Alarm.set(ServiceAPUnavailable, error)
        {:ok, :fault, %{state | last_error: error}}
    end
  end

  defp rollback_failed_verification(:verifying_automatic), do: :ok
  defp rollback_failed_verification(:verifying_recovery), do: Actions.rollback_transaction()

  defp fail_closed(state, reason) do
    error = %PlcRemote.Error{
      subsystem: :service,
      operation: :rollback_transaction,
      reason: reason
    }

    Logger.error(
      "Unable to roll back onsite settings; closing service access: #{inspect(reason)}"
    )

    state = Actions.leave_access_point(state)
    Alarm.set(ServiceAPUnavailable, error)
    {:ok, :fault, %{state | last_error: error, verification_deadline: nil}}
  end

  defp commit_verification(:verifying_automatic), do: Actions.mark_commissioned()
  defp commit_verification(:verifying_recovery), do: Actions.commit_transaction()
end
