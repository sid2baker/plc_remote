defmodule PlcRemote.Recovery.Runtime do
  @moduledoc "Subscribes to remote-access health and schedules explicit Recovery FSM stages."

  use GenServer

  require Logger

  alias PlcRemote.Events.{ConfigurationChanged, FirmwareChanged, ServiceChanged}
  alias PlcRemote.Health.Alarms.RemoteAccessUnavailable
  alias PlcRemote.Recovery.{Actions, RebootBudget, State, Status}

  @fsm_name PlcRemote.Recovery.FSM
  @stable_reset_ms 600_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec status() :: Status.t()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec reset_reboot_budget() :: :ok | {:error, term()}
  def reset_reboot_budget, do: GenServer.call(__MODULE__, :reset_reboot_budget)

  @impl GenServer
  def init(_opts) do
    :ok = PlcRemote.Events.subscribe()
    :ok = Alarmist.subscribe(RemoteAccessUnavailable)
    settings = PlcRemote.Configuration.current()
    path = Application.get_env(:plc_remote, :recovery_state_path)

    payload = %State{
      runtime: self(),
      settings: settings,
      path: path,
      consecutive_reboots: RebootBudget.load(path)
    }

    {:ok, _pid} = PlcRemote.Recovery.FSM.start_link(payload: payload, name: @fsm_name)
    state = %{stage_timer: nil, stable_timer: nil}
    send(self(), :observe_alarm)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, current_status(), state}

  def handle_call(:reset_reboot_budget, _from, state) do
    case Actions.reset_budget(current_payload()) do
      {:ok, payload} ->
        transition(:refresh, payload)
        {:reply, :ok, state}

      {:error, reason, _payload} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:observe_alarm, state) do
    {:noreply, apply_alarm_state(Alarmist.alarm_state(RemoteAccessUnavailable), state)}
  end

  def handle_info(%Alarmist.Event{id: RemoteAccessUnavailable, state: alarm_state}, state) do
    {:noreply, apply_alarm_state(alarm_state, state)}
  end

  def handle_info(%ConfigurationChanged{}, state) do
    settings = PlcRemote.Configuration.current()
    transition(:refresh, %{current_payload() | settings: settings})
    {:noreply, state}
  end

  def handle_info(%FirmwareChanged{status: firmware}, state) do
    transition(:refresh, %{current_payload() | firmware_validation: firmware.validation})
    {:noreply, state}
  end

  def handle_info(%ServiceChanged{status: %{active: true}}, state) do
    transition(:service_access_started, PlcRemote.Clock.now_ms())
    {:noreply, state |> cancel_stage_timer() |> cancel_stable_timer()}
  end

  def handle_info(%ServiceChanged{status: %{active: false}}, state) do
    {:noreply, apply_alarm_state(Alarmist.alarm_state(RemoteAccessUnavailable), state)}
  end

  def handle_info({:recovery_stage_due, event}, state) do
    transition(event, nil)
    {:noreply, %{state | stage_timer: nil} |> schedule_next_stage()}
  end

  def handle_info(:reset_stable_budget, state) do
    state = %{state | stable_timer: nil}
    if lifecycle() == :healthy, do: reset_stable_budget()
    {:noreply, state}
  end

  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cancel_timer(state.stage_timer)
    cancel_timer(state.stable_timer)
    :ok
  end

  defp reset_stable_budget do
    case Actions.reset_budget(current_payload()) do
      {:ok, payload} ->
        Logger.info("Remote access remained stable; automatic reboot budget reset")
        transition(:refresh, payload)

      {:error, _reason, _payload} ->
        :ok
    end
  end

  defp apply_alarm_state(:set, state) do
    cond do
      PlcRemote.Health.Reporter.service_access() == :active ->
        transition(:service_access_started, PlcRemote.Clock.now_ms())
        state |> cancel_stage_timer() |> cancel_stable_timer()

      lifecycle() == :healthy ->
        transition(:outage_set, PlcRemote.Clock.now_ms())
        state |> cancel_stable_timer() |> schedule_next_stage()

      true ->
        state |> cancel_stable_timer() |> schedule_next_stage()
    end
  end

  defp apply_alarm_state(_clear_or_unknown, state) do
    if lifecycle() != :healthy do
      transition(:outage_cleared, PlcRemote.Clock.now_ms())
    end

    state |> cancel_stage_timer() |> schedule_stable_reset()
  end

  defp schedule_next_stage(state) do
    cancel_timer(state.stage_timer)
    settings = current_payload().settings
    thresholds = thresholds(settings)
    offline_since = current_payload().offline_since || PlcRemote.Clock.now_ms()
    now = PlcRemote.Clock.now_ms()

    case next_stage(lifecycle(), thresholds) do
      nil ->
        %{state | stage_timer: nil}

      {event, threshold} ->
        delay = max(offline_since + threshold - now, 1)

        %{
          state
          | stage_timer: PlcRemote.Clock.send_after(self(), {:recovery_stage_due, event}, delay)
        }
    end
  end

  defp next_stage(:outage_observed, thresholds), do: {:reconnect_due, thresholds.reconnect}
  defp next_stage(:reconnect, thresholds), do: {:network_reapply_due, thresholds.reapply_network}
  defp next_stage(:network_reapply, thresholds), do: {:uplink_cycle_due, thresholds.cycle_uplink}

  defp next_stage(:uplink_cycle, thresholds),
    do: {:tailscale_restart_due, thresholds.restart_tailscale}

  defp next_stage(:tailscale_restart, thresholds), do: {:reboot_due, thresholds.reboot}
  defp next_stage(_lifecycle, _thresholds), do: nil

  defp schedule_stable_reset(state) do
    if current_payload().consecutive_reboots > 0 and is_nil(state.stable_timer) do
      %{
        state
        | stable_timer: PlcRemote.Clock.send_after(self(), :reset_stable_budget, @stable_reset_ms)
      }
    else
      state
    end
  end

  defp current_status do
    payload = current_payload()
    now = PlcRemote.Clock.now_ms()

    %Status{
      lifecycle: lifecycle(),
      consecutive_reboots: payload.consecutive_reboots,
      last_action: payload.last_action,
      last_action_ago_seconds: elapsed_seconds(payload.last_action_at, now),
      offline_for_seconds: elapsed_seconds(payload.offline_since, now),
      stable_for_seconds: elapsed_seconds(payload.stable_since, now)
    }
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

  defp elapsed_seconds(nil, _now), do: nil
  defp elapsed_seconds(since, now), do: div(now - since, 1_000)

  defp cancel_stage_timer(state) do
    cancel_timer(state.stage_timer)
    %{state | stage_timer: nil}
  end

  defp cancel_stable_timer(state) do
    cancel_timer(state.stable_timer)
    %{state | stable_timer: nil}
  end

  defp transition(event, payload), do: PlcRemote.FSM.transition(@fsm_name, event, payload)
  defp current_payload, do: PlcRemote.FSM.payload(@fsm_name)
  defp lifecycle, do: PlcRemote.FSM.lifecycle(@fsm_name)
  defp cancel_timer(timer), do: PlcRemote.FSM.cancel_timer(timer)
end
