defmodule PlcRemote.Recovery.Actions do
  @moduledoc "Effect boundary for staged automatic recovery."

  require Logger

  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.RecoveryRebootBudgetExhausted
  alias PlcRemote.Recovery.{RebootBudget, Safety, State}

  @spec perform(atom(), State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def perform(:reconnect, state) do
    Logger.warning("Recovery stage: reconnecting Tailscale")
    PlcRemote.Tailscale.reconnect()
    {:ok, completed(state, :reconnect)}
  end

  def perform(:reapply_network, state) do
    Logger.warning("Recovery stage: reapplying network roles")
    _result = PlcRemote.Network.reapply()
    {:ok, completed(state, :reapply_network)}
  end

  def perform(:cycle_uplink, state) do
    Logger.warning("Recovery stage: cycling the Ethernet Internet uplink")
    _result = PlcRemote.Network.cycle_uplink()
    {:ok, completed(state, :cycle_uplink)}
  end

  def perform(:restart_tailscale, state) do
    Logger.warning("Recovery stage: restarting the complete Tailscale boundary")
    :ok = PlcRemote.Tailscale.Supervisor.restart_runtime()
    {:ok, completed(state, :restart_tailscale)}
  end

  def perform(:reboot, state) do
    recovery = state.settings.recovery

    case Safety.reboot_allowed?(
           recovery,
           state.firmware_validation,
           state.consecutive_reboots
         ) do
      :ok ->
        perform_reboot(state, recovery)

      {:error, :budget_exhausted} ->
        Alarm.set(RecoveryRebootBudgetExhausted, %{count: state.consecutive_reboots})
        {:error, :budget_exhausted, completed(state, :reboot)}

      {:error, reason} ->
        {:error, reason, completed(state, :reboot)}
    end
  end

  @spec reset_budget(State.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def reset_budget(state) do
    case RebootBudget.set(state.path, 0) do
      :ok ->
        Alarm.clear(RecoveryRebootBudgetExhausted)
        {:ok, %{state | consecutive_reboots: 0}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp perform_reboot(state, recovery) do
    next_count = state.consecutive_reboots + 1

    case RebootBudget.set(state.path, next_count) do
      :ok ->
        Logger.error(
          "Remote access unavailable after all recovery stages; " <>
            "performing bounded reboot #{next_count}/#{recovery.max_consecutive_reboots}"
        )

        system_adapter().reboot()
        {:ok, completed(%{state | consecutive_reboots: next_count}, :reboot)}

      {:error, reason} ->
        {:error, {:budget_persist_failed, reason}, state}
    end
  end

  defp completed(state, action) do
    %{state | last_action: action, last_action_at: PlcRemote.Clock.now_ms()}
  end

  defp system_adapter, do: Application.fetch_env!(:plc_remote, :system_adapter)
end
