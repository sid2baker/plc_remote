defmodule PlcRemote.RecoveryManager do
  @moduledoc """
  Escalates prolonged loss of remote access without creating reboot loops.

  The manager starts with inexpensive Tailscale reconnects, then reapplies and
  cycles the Ethernet uplink, then restarts the complete Tailscale boundary. A full device
  reboot is the final action and has a persistent consecutive-reboot budget.
  Service mode, uncommissioned devices, disabled Tailscale, and unvalidated
  firmware suppress automatic reboots.
  """

  use GenServer

  require Logger

  alias PlcRemote.Recovery.{Policy, Safety, Store}

  @check_interval_ms 10_000
  @minimum_action_spacing_ms 60_000
  @stable_reset_ms 600_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current recovery stage and persistent reboot budget."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Resets the automatic reboot budget from a trusted local maintenance session."
  @spec reset_reboot_budget() :: :ok | {:error, term()}
  def reset_reboot_budget, do: GenServer.call(__MODULE__, :reset_reboot_budget)

  @impl GenServer
  def init(_opts) do
    path = Application.get_env(:plc_remote, :recovery_state_path)
    persisted = Store.load(path)
    schedule_check(0)

    {:ok,
     %{
       settings: PlcRemote.Configuration.get(),
       path: path,
       consecutive_reboots: persisted.consecutive_reboots,
       offline_since: nil,
       stable_since: nil,
       completed: MapSet.new(),
       last_action: nil,
       last_action_at: nil
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    now = now_ms()

    status = %{
      completed_stages: MapSet.to_list(state.completed),
      consecutive_reboots: state.consecutive_reboots,
      last_action: state.last_action,
      last_action_ago_seconds: elapsed_seconds(state.last_action_at, now),
      offline_for_seconds: elapsed_seconds(state.offline_since, now),
      stable_for_seconds: elapsed_seconds(state.stable_since, now)
    }

    {:reply, status, state}
  end

  def handle_call(:reset_reboot_budget, _from, state) do
    case persist_reboot_count(state, 0) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:check_recovery, state) do
    state = evaluate(state, now_ms())
    schedule_check()
    {:noreply, state}
  end

  def handle_info({:settings_updated, settings, _auth_key}, state) do
    {:noreply, %{state | settings: settings}}
  end

  defp evaluate(state, now) do
    tailscale = safe_status(PlcRemote.TailscaleManager)
    service = safe_status(PlcRemote.ServiceMode)

    cond do
      not state.settings.commissioned or not state.settings.tailscale.enabled ->
        reset_observation(state)

      service[:active] ->
        reset_observation(state)

      tailscale[:state] == :connected ->
        observe_stable_connection(state, now)

      true ->
        observe_outage(state, now)
    end
  end

  defp observe_stable_connection(state, now) do
    stable_since = state.stable_since || now
    state = %{state | stable_since: stable_since, offline_since: nil, completed: MapSet.new()}

    if state.consecutive_reboots > 0 and now - stable_since >= @stable_reset_ms do
      case persist_reboot_count(state, 0) do
        {:ok, state} ->
          Logger.info("Tailscale remained stable; automatic recovery reboot budget reset")
          state

        {:error, _reason, state} ->
          state
      end
    else
      state
    end
  end

  defp observe_outage(state, now) do
    offline_since = state.offline_since || now
    state = %{state | offline_since: offline_since, stable_since: nil}
    elapsed = now - offline_since

    if recently_acted?(state, now) do
      state
    else
      case Policy.next_action(elapsed, state.completed, thresholds(state.settings)) do
        nil -> state
        action -> perform(action, state)
      end
    end
  end

  defp perform(:reconnect = action, state) do
    Logger.warning("Recovery stage: reconnecting Tailscale")
    PlcRemote.TailscaleManager.reconnect()
    complete(state, action)
  end

  defp perform(:reapply_network = action, state) do
    Logger.warning("Recovery stage: reapplying network roles")
    _result = PlcRemote.NetworkManager.reapply()
    complete(state, action)
  end

  defp perform(:cycle_uplink = action, state) do
    Logger.warning("Recovery stage: cycling the Ethernet Internet uplink")
    _result = PlcRemote.NetworkManager.cycle_uplink()
    complete(state, action)
  end

  defp perform(:restart_tailscale = action, state) do
    Logger.warning("Recovery stage: restarting the complete Tailscale boundary")
    :ok = PlcRemote.TailscaleSupervisor.restart_runtime()
    complete(state, action)
  end

  defp perform(:reboot = action, state) do
    recovery = state.settings.recovery
    firmware_status = system_adapter().firmware_validation_status()

    case Safety.reboot_allowed?(recovery, firmware_status, state.consecutive_reboots) do
      {:error, :disabled} ->
        Logger.warning("Recovery reboot suppressed by configuration")
        complete(state, action)

      {:error, :firmware_unvalidated} ->
        Logger.warning("Recovery reboot delegated to candidate firmware validation policy")
        complete(state, action)

      {:error, :budget_exhausted} ->
        Logger.error("Recovery reboot budget exhausted; leaving device running for diagnostics")
        complete(state, action)

      :ok ->
        next_count = state.consecutive_reboots + 1

        case persist_reboot_count(state, next_count) do
          {:ok, state} ->
            Logger.error(
              "Remote access unavailable after all recovery stages; " <>
                "performing bounded reboot #{next_count}/#{recovery.max_consecutive_reboots}"
            )

            system_adapter().reboot()
            complete(state, action)

          {:error, reason, state} ->
            Logger.error(
              "Recovery reboot cancelled because its budget could not persist: #{inspect(reason)}"
            )

            complete(state, action)
        end
    end
  end

  defp persist_reboot_count(state, count) do
    persisted = %{consecutive_reboots: count}

    case Store.save(state.path, persisted) do
      :ok -> {:ok, %{state | consecutive_reboots: count}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp complete(state, action) do
    %{
      state
      | completed: MapSet.put(state.completed, action),
        last_action: action,
        last_action_at: now_ms()
    }
  end

  defp recently_acted?(%{last_action_at: nil}, _now), do: false

  defp recently_acted?(state, now) do
    now - state.last_action_at < @minimum_action_spacing_ms
  end

  defp reset_observation(state) do
    %{state | offline_since: nil, stable_since: nil, completed: MapSet.new()}
  end

  defp thresholds(settings) do
    reboot = settings.recovery.reboot_after_ms

    %{
      reconnect: min(120_000, div(reboot, 6)),
      reapply_network: min(300_000, div(reboot, 4)),
      cycle_uplink: min(900_000, div(reboot, 2)),
      restart_tailscale: min(1_800_000, div(reboot * 3, 4)),
      reboot: reboot
    }
  end

  defp safe_status(module) do
    module.status()
  catch
    :exit, _reason -> %{}
  end

  defp elapsed_seconds(nil, _now), do: nil
  defp elapsed_seconds(since, now), do: div(now - since, 1_000)

  defp schedule_check(delay \\ @check_interval_ms) do
    Process.send_after(self(), :check_recovery, delay)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp system_adapter, do: Application.fetch_env!(:plc_remote, :system_adapter)
end
