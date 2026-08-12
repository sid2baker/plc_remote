defmodule PlcRemote.Firmware.Actions do
  @moduledoc "Effect boundary for A/B firmware validation, rollback, and update expectation."

  require Logger

  alias PlcRemote.Firmware.{ExpectationStore, State}

  @spec validate(State.t(), String.t()) ::
          {:ok, State.t()} | {:error, PlcRemote.Error.t(), State.t()}
  def validate(state, reason) do
    Logger.info("Validating candidate firmware: #{reason}")

    case system_adapter().validate_firmware() do
      :ok ->
        ExpectationStore.clear(state.expectation_path)

        {:ok,
         %{
           state
           | validation: :validated,
             remote_expected: false,
             last_action: :validated,
             last_error: nil
         }}

      {:error, reason} ->
        error = %PlcRemote.Error{subsystem: :firmware, operation: :validate, reason: reason}
        {:error, error, %{state | last_error: error}}
    end
  end

  @spec revert(State.t()) :: {:ok, State.t()} | {:error, PlcRemote.Error.t(), State.t()}
  def revert(state) do
    Logger.error(
      "Candidate firmware connectivity evidence requires rollback to the previous slot"
    )

    case system_adapter().revert_firmware() do
      :ok ->
        {:ok, %{state | last_action: :revert_requested, last_error: nil}}

      {:error, reason} ->
        error = %PlcRemote.Error{subsystem: :firmware, operation: :revert, reason: reason}
        {:error, error, %{state | last_error: error}}
    end
  end

  @spec mark_expectation(State.t()) :: {:ok, State.t()} | {:error, PlcRemote.Error.t(), State.t()}
  def mark_expectation(state) do
    case ExpectationStore.mark(state.expectation_path) do
      :ok ->
        {:ok, %{state | remote_expected: true, last_error: nil}}

      {:error, reason} ->
        error = %PlcRemote.Error{subsystem: :firmware, operation: :prepare_update, reason: reason}
        {:error, error, %{state | last_error: error}}
    end
  end

  defp system_adapter, do: Application.fetch_env!(:plc_remote, :system_adapter)
end
