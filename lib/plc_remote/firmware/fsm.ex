defmodule PlcRemote.Firmware.FSM do
  @moduledoc "Explicit A/B firmware candidate, validation, and rollback lifecycle."

  @fsm """
  [*] --> initializing : boot
  initializing --> validated : initialized_validated
  initializing --> unknown : initialized_unknown
  initializing --> candidate : initialized_candidate
  candidate --> candidate : evidence_changed
  candidate --> validated : validate
  candidate --> validation_failed : validation_failed
  candidate --> revert_requested : revert
  candidate --> revert_failed : revert_failed
  validated --> validated : prepare_update
  validated --> validated : refresh
  candidate --> candidate : refresh
  unknown --> unknown : refresh
  validation_failed --> validation_failed : refresh
  revert_requested --> revert_requested : refresh
  revert_failed --> revert_failed : refresh
  validated --> [*] : shutdown
  candidate --> [*] : shutdown
  unknown --> [*] : shutdown
  validation_failed --> [*] : shutdown
  revert_requested --> [*] : shutdown
  revert_failed --> [*] : shutdown
  """

  use Finitomata,
    fsm: @fsm,
    syntax: :state_diagram,
    telemetria_levels: :none,
    impl_for: :none

  alias PlcRemote.Firmware.{Actions, State}
  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.{FirmwareCandidateUnvalidated, FirmwareValidationFailed}

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, %State{} = state),
    do: {:ok, :initializing, state}

  def on_transition(:initializing, :initialized_validated, _event_payload, %State{} = state),
    do: {:ok, :validated, report_health(:validated, state)}

  def on_transition(:initializing, :initialized_candidate, _event_payload, %State{} = state),
    do: {:ok, :candidate, report_health(:candidate, state)}

  def on_transition(:initializing, :initialized_unknown, _event_payload, %State{} = state),
    do: {:ok, :unknown, report_health(:unknown, state)}

  def on_transition(:candidate, :evidence_changed, %State{} = updated, %State{}),
    do: {:ok, :candidate, report_health(:candidate, updated)}

  def on_transition(:candidate, :validate, reason, %State{} = state) do
    case Actions.validate(state, reason) do
      {:ok, state} ->
        {:ok, :validated, report_health(:validated, state)}

      {:error, _error, state} ->
        {:ok, :validation_failed, report_health(:validation_failed, state)}
    end
  end

  def on_transition(:candidate, :revert, _event_payload, %State{} = state) do
    case Actions.revert(state) do
      {:ok, state} -> {:ok, :revert_requested, report_health(:revert_requested, state)}
      {:error, _error, state} -> {:ok, :revert_failed, report_health(:revert_failed, state)}
    end
  end

  def on_transition(:validated, :prepare_update, _event_payload, %State{} = state) do
    case Actions.mark_expectation(state) do
      {:ok, state} -> {:ok, :validated, state}
      {:error, error, _state} -> {:error, error}
    end
  end

  def on_transition(current, :refresh, %State{} = updated, %State{}),
    do: {:ok, current, report_health(current, updated)}

  def on_transition(current, event, _event_payload, _state),
    do: {:error, {:invalid_firmware_transition, current, event}}

  @impl Finitomata
  def on_enter(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_exit(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_failure(_event, _payload, _state), do: :ok

  defp report_health(lifecycle, state) do
    Alarm.report(FirmwareCandidateUnvalidated, lifecycle == :candidate, %{lifecycle: lifecycle})

    Alarm.report(
      FirmwareValidationFailed,
      lifecycle in [:validation_failed, :revert_failed],
      state.last_error
    )

    state
  end
end
