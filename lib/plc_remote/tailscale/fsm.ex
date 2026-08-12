defmodule PlcRemote.Tailscale.FSM do
  @moduledoc "The explicit lifecycle for embedded Tailscale and its fixed PLC listener."

  @fsm """
  [*] --> disabled : boot
  disabled --> disabled : evaluate
  disabled --> waiting_for_network : wait_for_network
  disabled --> connecting : connect
  waiting_for_network --> waiting_for_network : evaluate
  waiting_for_network --> connecting : connect
  waiting_for_network --> disabled : disable
  connecting --> connecting : evaluate
  connecting --> connected : connected
  connecting --> retry_wait : failed
  connecting --> waiting_for_network : wait_for_network
  connecting --> disabled : disable
  connected --> connected : evaluate
  connected --> connecting : reconnect
  connected --> retry_wait : failed
  connected --> waiting_for_network : wait_for_network
  connected --> disabled : disable
  retry_wait --> retry_wait : evaluate
  retry_wait --> connecting : connect
  retry_wait --> waiting_for_network : wait_for_network
  retry_wait --> disabled : disable
  disabled --> [*] : shutdown
  waiting_for_network --> [*] : shutdown
  connecting --> [*] : shutdown
  connected --> [*] : shutdown
  retry_wait --> [*] : shutdown
  """

  use Finitomata,
    fsm: @fsm,
    syntax: :state_diagram,
    telemetria_levels: :none,
    impl_for: :none

  require Logger

  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.{TailscaleListenerUnavailable, TailscaleUnavailable}
  alias PlcRemote.Tailscale.{Actions, State}

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, %State{} = state) do
    state = report_health(:disabled, Actions.stop(state))
    {:ok, :disabled, state}
  end

  def on_transition(current, :evaluate, %State{} = updated, %State{}) do
    choose_lifecycle(current, updated)
  end

  def on_transition(current, :evaluate, _event_payload, %State{} = state) do
    choose_lifecycle(current, state)
  end

  def on_transition(_current, :disable, _event_payload, %State{} = state) do
    state = state |> Actions.stop() |> clear_transient()
    {:ok, :disabled, report_health(:disabled, state)}
  end

  def on_transition(_current, :wait_for_network, _event_payload, %State{} = state) do
    state = Actions.stop(state)
    {:ok, :waiting_for_network, report_health(:waiting_for_network, state)}
  end

  def on_transition(_current, :connect, _event_payload, %State{} = state) do
    state = Actions.stop(state)
    task = Actions.connect(state)

    state =
      state
      |> Map.put(:connect_task, task)
      |> Map.put(:retry_at, nil)
      |> Map.put(:last_error, nil)
      |> report_health(:connecting)

    {:ok, :connecting, state}
  end

  def on_transition(
        :connecting,
        :connected,
        {connect_pid, device, listener, tailnet_ipv4},
        %State{} = state
      ) do
    if state.connect_task == connect_pid do
      connect_succeeded(state, device, listener, tailnet_ipv4)
    else
      {:ok, :connecting, state}
    end
  end

  def on_transition(:connecting, :failed, {:connect, connect_pid, reason}, %State{} = state) do
    if state.connect_task == connect_pid do
      connect_failed(%{state | connect_task: nil}, reason)
    else
      {:ok, :connecting, state}
    end
  end

  def on_transition(:connected, :failed, {listener_pid, reason}, %State{} = state) do
    if state.listener_task == listener_pid do
      connect_failed(%{state | listener_task: nil}, {:listener_stopped, reason})
    else
      {:ok, :connected, state}
    end
  end

  def on_transition(:connecting, :failed, reason, %State{} = state),
    do: connect_failed(state, reason)

  def on_transition(:connected, :reconnect, _event_payload, %State{} = state) do
    state = state |> Actions.stop() |> Map.put(:failure_count, 0)
    task = Actions.connect(state)
    {:ok, :connecting, report_health(:connecting, %{state | connect_task: task})}
  end

  def on_transition(current, event, _event_payload, %State{} = _state) do
    {:error, {:invalid_tailscale_transition, current, event}}
  end

  @impl Finitomata
  def on_enter(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_exit(_lifecycle, _state), do: :ok

  @impl Finitomata
  def on_failure(_event, _payload, _state), do: :ok

  @impl Finitomata
  def on_terminate(%Finitomata.State{payload: %State{} = state}) do
    _state = Actions.stop(state)
    Alarm.clear(TailscaleUnavailable)
    Alarm.clear(TailscaleListenerUnavailable)
    :ok
  end

  defp choose_lifecycle(current, state) do
    desired = desired_lifecycle(state)
    resolve_lifecycle(current, desired, state)
  end

  defp desired_lifecycle(%State{settings: %{tailscale: %{enabled: false}}}), do: :disabled

  defp desired_lifecycle(%State{network: %{connection: connection}}) when connection != :internet,
    do: :waiting_for_network

  defp desired_lifecycle(%State{}), do: :connected

  defp resolve_lifecycle(:disabled, :disabled, state),
    do: {:ok, :disabled, report_health(:disabled, clear_transient(state))}

  defp resolve_lifecycle(current, :disabled, state),
    do: on_transition(current, :disable, nil, state)

  defp resolve_lifecycle(:waiting_for_network, :waiting_for_network, state),
    do: {:ok, :waiting_for_network, report_health(:waiting_for_network, state)}

  defp resolve_lifecycle(current, :waiting_for_network, state),
    do: on_transition(current, :wait_for_network, nil, state)

  defp resolve_lifecycle(:connected, :connected, state) do
    if listener_matches_network?(state) do
      {:ok, :connected, report_health(:connected, state)}
    else
      on_transition(:connected, :reconnect, nil, state)
    end
  end

  defp resolve_lifecycle(:connecting, :connected, %{connect_task: task} = state)
       when is_pid(task),
       do: {:ok, :connecting, report_health(:connecting, state)}

  defp resolve_lifecycle(current, :connected, state),
    do: on_transition(current, :connect, nil, state)

  defp connect_succeeded(state, device, listener, tailnet_ipv4) do
    machine_ifname = PlcRemote.Proxy.Policy.machine_ifname(state.settings, state.network)

    if is_nil(listener) and is_binary(machine_ifname) do
      connect_failed(state, :plc_listener_unavailable)
    else
      listener_task =
        if is_nil(listener),
          do: nil,
          else: Actions.start_listener(state, listener, machine_ifname)

      log_connected(tailnet_ipv4, listener, state.settings)

      state = %{
        state
        | device: device,
          listener: listener,
          tailnet_ipv4: format_ip(tailnet_ipv4),
          proxy_ifname: if(is_nil(listener), do: nil, else: machine_ifname),
          connect_task: nil,
          listener_task: listener_task,
          pending_auth_key: nil,
          connected_since: PlcRemote.Clock.now_ms(),
          failure_count: 0,
          retry_at: nil,
          last_error: nil
      }

      {:ok, :connected, report_health(:connected, state)}
    end
  end

  defp connect_failed(state, reason) do
    failure_count = state.failure_count + 1
    retry_delay = PlcRemote.RetryPolicy.delay(failure_count)

    Logger.warning(
      "Tailscale connection unavailable: #{inspect(reason)}; " <>
        "retrying in #{div(retry_delay, 1_000)} seconds"
    )

    error = %PlcRemote.Error{subsystem: :tailscale, operation: :connect, reason: reason}

    state =
      state
      |> Actions.stop()
      |> Map.put(:failure_count, failure_count)
      |> Map.put(:retry_at, PlcRemote.Clock.now_ms() + retry_delay)
      |> Map.put(:last_error, error)
      |> report_health(:retry_wait)

    {:ok, :retry_wait, state}
  end

  defp report_health(%State{} = state, lifecycle), do: report_health(lifecycle, state)

  defp report_health(lifecycle, %State{} = state) do
    unavailable? = state.settings.tailscale.enabled and lifecycle != :connected

    Alarm.report(TailscaleUnavailable, unavailable?, %{
      lifecycle: lifecycle,
      error: state.last_error
    })

    listener_unavailable? =
      lifecycle == :connected and state.settings.machine.enabled and
        (is_nil(state.listener) or not is_binary(state.proxy_ifname))

    Alarm.report(TailscaleListenerUnavailable, listener_unavailable?, %{
      interface: state.proxy_ifname,
      error: state.last_error
    })

    state
  end

  defp clear_transient(state) do
    %{
      state
      | pending_auth_key: nil,
        failure_count: 0,
        retry_at: nil,
        last_error: nil
    }
  end

  defp listener_matches_network?(state) do
    expected = PlcRemote.Proxy.Policy.machine_ifname(state.settings, state.network)
    expected == state.proxy_ifname
  end

  defp log_connected(tailnet_ipv4, nil, _settings) do
    Logger.info("Tailscale joined at #{format_ip(tailnet_ipv4)}; PLC proxy is not configured")
  end

  defp log_connected(tailnet_ipv4, _listener, settings) do
    Logger.info(
      "Tailscale PLC proxy listening on #{format_ip(tailnet_ipv4)}:" <>
        "#{settings.tailscale.listen_port} for " <>
        "#{settings.machine.plc_address}:#{settings.tailscale.destination_port}"
    )
  end

  defp format_ip(address), do: address |> :inet.ntoa() |> to_string()
end
