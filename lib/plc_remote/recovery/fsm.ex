defmodule PlcRemote.Recovery.FSM do
  @moduledoc "Event-driven staged remote-access recovery lifecycle."

  @fsm """
  [*] --> healthy : boot
  healthy --> outage_observed : outage_set
  healthy --> healthy : service_access_started
  outage_observed --> healthy : service_access_started
  reconnect --> healthy : service_access_started
  network_reapply --> healthy : service_access_started
  uplink_cycle --> healthy : service_access_started
  tailscale_restart --> healthy : service_access_started
  reboot --> healthy : service_access_started
  reboot_suppressed --> healthy : service_access_started
  exhausted --> healthy : service_access_started
  outage_observed --> reconnect : reconnect_due
  reconnect --> network_reapply : network_reapply_due
  network_reapply --> uplink_cycle : uplink_cycle_due
  uplink_cycle --> tailscale_restart : tailscale_restart_due
  tailscale_restart --> reboot : reboot_due
  reboot --> reboot_suppressed : reboot_suppressed
  reboot --> exhausted : budget_exhausted
  outage_observed --> healthy : outage_cleared
  reconnect --> healthy : outage_cleared
  network_reapply --> healthy : outage_cleared
  uplink_cycle --> healthy : outage_cleared
  tailscale_restart --> healthy : outage_cleared
  reboot --> healthy : outage_cleared
  reboot_suppressed --> healthy : outage_cleared
  exhausted --> healthy : outage_cleared
  healthy --> healthy : refresh
  outage_observed --> outage_observed : refresh
  reconnect --> reconnect : refresh
  network_reapply --> network_reapply : refresh
  uplink_cycle --> uplink_cycle : refresh
  tailscale_restart --> tailscale_restart : refresh
  reboot --> reboot : refresh
  reboot_suppressed --> reboot_suppressed : refresh
  exhausted --> exhausted : refresh
  healthy --> [*] : shutdown
  outage_observed --> [*] : shutdown
  reconnect --> [*] : shutdown
  network_reapply --> [*] : shutdown
  uplink_cycle --> [*] : shutdown
  tailscale_restart --> [*] : shutdown
  reboot --> [*] : shutdown
  reboot_suppressed --> [*] : shutdown
  exhausted --> [*] : shutdown
  """

  use Finitomata,
    fsm: @fsm,
    syntax: :state_diagram,
    telemetria_levels: :none,
    impl_for: :none

  alias PlcRemote.Recovery.{Actions, State}

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, %State{} = state), do: {:ok, :healthy, state}

  def on_transition(:healthy, :outage_set, now, %State{} = state) do
    {:ok, :outage_observed, %{state | offline_since: now, stable_since: nil}}
  end

  def on_transition(:outage_observed, :reconnect_due, _event_payload, %State{} = state) do
    perform(:reconnect, :reconnect, state)
  end

  def on_transition(:reconnect, :network_reapply_due, _event_payload, %State{} = state) do
    perform(:reapply_network, :network_reapply, state)
  end

  def on_transition(:network_reapply, :uplink_cycle_due, _event_payload, %State{} = state) do
    perform(:cycle_uplink, :uplink_cycle, state)
  end

  def on_transition(:uplink_cycle, :tailscale_restart_due, _event_payload, %State{} = state) do
    perform(:restart_tailscale, :tailscale_restart, state)
  end

  def on_transition(:tailscale_restart, :reboot_due, _event_payload, %State{} = state) do
    case Actions.perform(:reboot, state) do
      {:ok, state} -> {:ok, :reboot, state}
      {:error, :budget_exhausted, state} -> {:ok, :exhausted, state}
      {:error, _reason, state} -> {:ok, :reboot_suppressed, state}
    end
  end

  def on_transition(:healthy, :service_access_started, _now, %State{} = state),
    do: {:ok, :healthy, clear_observation(state, nil)}

  def on_transition(current, :service_access_started, _now, %State{} = state)
      when current != :healthy,
      do: {:ok, :healthy, clear_observation(state, nil)}

  def on_transition(current, :outage_cleared, now, %State{} = state)
      when current != :healthy,
      do: {:ok, :healthy, clear_observation(state, now)}

  def on_transition(current, :refresh, %State{} = updated, %State{}),
    do: {:ok, current, updated}

  def on_transition(current, event, _event_payload, _state),
    do: {:error, {:invalid_recovery_transition, current, event}}

  @impl Finitomata
  def on_enter(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_exit(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_failure(_event, _payload, _state), do: :ok

  defp clear_observation(state, stable_since) do
    %{state | offline_since: nil, stable_since: stable_since, last_error: nil}
  end

  defp perform(action, destination, state) do
    case Actions.perform(action, state) do
      {:ok, state} ->
        {:ok, destination, state}

      {:error, reason, state} ->
        error = %PlcRemote.Error{subsystem: :recovery, operation: action, reason: reason}
        {:ok, destination, %{state | last_error: error}}
    end
  end
end
