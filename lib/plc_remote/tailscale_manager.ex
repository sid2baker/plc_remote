defmodule PlcRemote.TailscaleManager do
  @moduledoc """
  Owns the experimental `tailscale-rs` device and its fixed PLC TCP proxy.

  This is intentionally not a subnet router. An authorized tailnet client
  connects to the gateway's tailnet IPv4 address and configured listener port;
  the gateway opens the one configured PLC destination on the isolated LAN.
  """

  use GenServer

  require Logger

  alias PlcRemote.{Commissioning, Configuration, RetryPolicy}

  @commission_retry_ms 5_000
  @connect_timeout_ms 60_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns non-secret Tailscale and proxy status."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Immediately restarts the userspace Tailscale connection."
  @spec reconnect() :: :ok
  def reconnect, do: GenServer.cast(__MODULE__, :reconnect)

  @impl GenServer
  def init(_opts) do
    settings = Configuration.get()
    send(self(), :configure)

    {:ok,
     %{
       adapter: Application.fetch_env!(:plc_remote, :tailscale_adapter),
       settings: settings,
       state: :disabled,
       reason: nil,
       tailnet_ipv4: nil,
       listen_port: settings.tailscale.listen_port,
       destination: destination(settings),
       device: nil,
       listener: nil,
       connect_task: nil,
       listener_task: nil,
       connect_timer: nil,
       retry_timer: nil,
       retry_at: nil,
       failure_count: 0,
       connected_since: nil,
       pending_auth_key: nil
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    public_status = %{
      active_sessions: active_session_count(),
      connected_for_seconds: elapsed_seconds(state.connected_since),
      destination: state.destination,
      failure_count: state.failure_count,
      listen_port: state.listen_port,
      reason: state.reason,
      retry_in_seconds: retry_in_seconds(state.retry_at),
      state: state.state,
      tailnet_ipv4: state.tailnet_ipv4
    }

    {:reply, public_status, state}
  end

  @impl GenServer
  def handle_cast(:reconnect, state) do
    state = %{state | failure_count: 0}
    {:noreply, configure(state, state.pending_auth_key)}
  end

  @impl GenServer
  def handle_info(:configure, state) do
    {:noreply, configure(state, nil)}
  end

  def handle_info({:settings_updated, settings, auth_key}, state) do
    reconnect? =
      not is_nil(auth_key) or connection_settings(state.settings) != connection_settings(settings)

    state = %{
      state
      | settings: settings,
        pending_auth_key: auth_key || state.pending_auth_key,
        failure_count: if(reconnect?, do: 0, else: state.failure_count)
    }

    if reconnect? do
      {:noreply, configure(state, state.pending_auth_key)}
    else
      {:noreply, state}
    end
  end

  def handle_info({reference, result}, %{connect_task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    cancel_timer(state.connect_timer)
    state = %{state | connect_task: nil, connect_timer: nil}
    {:noreply, handle_connect_result(state, result)}
  end

  def handle_info({reference, result}, %{listener_task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    state = %{state | listener_task: nil}
    {:noreply, connection_failed(state, {:listener_stopped, result})}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    cond do
      task_reference(state.connect_task) == reference ->
        state = %{state | connect_task: nil}
        {:noreply, connection_failed(state, {:connect_task_stopped, reason})}

      task_reference(state.listener_task) == reference ->
        state = %{state | listener_task: nil}
        {:noreply, connection_failed(state, {:listener_task_stopped, reason})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:connect_timeout, state) do
    terminate_task(state.connect_task)
    state = %{state | connect_task: nil, connect_timer: nil}
    {:noreply, connection_failed(state, :connection_timeout)}
  end

  def handle_info(:retry_connection, state) do
    state = %{state | retry_timer: nil}
    {:noreply, configure(state, state.pending_auth_key)}
  end

  def handle_info(:complete_commissioning, %{state: :connected} = state) do
    {:noreply, maybe_complete_commissioning(state)}
  end

  def handle_info(:complete_commissioning, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _state = stop_connection(state)
    :ok
  end

  defp configure(state, auth_key) do
    state = stop_connection(state)
    settings = state.settings

    if settings.tailscale.enabled do
      start_connection(state, auth_key)
    else
      %{
        state
        | state: :disabled,
          reason: nil,
          listen_port: settings.tailscale.listen_port,
          destination: destination(settings),
          failure_count: 0,
          connected_since: nil,
          pending_auth_key: nil
      }
    end
  end

  defp start_connection(state, auth_key) do
    task =
      Task.Supervisor.async_nolink(PlcRemote.TailscaleConnectionTaskSupervisor, fn ->
        state.adapter.connect(state.settings, auth_key)
      end)

    timer = Process.send_after(self(), :connect_timeout, @connect_timeout_ms)

    %{
      state
      | state: :connecting,
        reason: nil,
        tailnet_ipv4: nil,
        listen_port: state.settings.tailscale.listen_port,
        destination: destination(state.settings),
        connect_task: task,
        connect_timer: timer,
        retry_at: nil,
        connected_since: nil,
        pending_auth_key: auth_key
    }
  end

  defp handle_connect_result(state, {:ok, device, listener, tailnet_ipv4}) do
    settings = state.settings
    adapter = state.adapter

    task =
      Task.Supervisor.async_nolink(PlcRemote.TailscaleConnectionTaskSupervisor, fn ->
        accept_loop(
          adapter,
          listener,
          settings.machine.plc_address,
          settings.tailscale.destination_port
        )
      end)

    Logger.info(
      "Tailscale PLC proxy listening on #{format_ip(tailnet_ipv4)}:#{settings.tailscale.listen_port} " <>
        "for #{destination(settings)}"
    )

    state
    |> Map.put(:state, :connected)
    |> Map.put(:reason, nil)
    |> Map.put(:tailnet_ipv4, format_ip(tailnet_ipv4))
    |> Map.put(:device, device)
    |> Map.put(:listener, listener)
    |> Map.put(:listener_task, task)
    |> Map.put(:failure_count, 0)
    |> Map.put(:connected_since, System.monotonic_time(:millisecond))
    |> Map.put(:retry_at, nil)
    |> Map.put(:pending_auth_key, nil)
    |> maybe_complete_commissioning()
  end

  defp handle_connect_result(state, {:error, reason}), do: connection_failed(state, reason)

  defp accept_loop(adapter, listener, address, port) do
    case adapter.accept(listener) do
      {:ok, stream} ->
        Logger.info(
          "Accepted PLC proxy connection from #{format_remote(adapter.remote_address(stream))}"
        )

        {:ok, _pid} =
          Task.Supervisor.start_child(PlcRemote.TailscaleSessionTaskSupervisor, fn ->
            PlcRemote.TcpProxy.relay(stream, address, port, adapter)
          end)

        accept_loop(adapter, listener, address, port)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_complete_commissioning(%{settings: %{commissioned: true}} = state), do: state

  defp maybe_complete_commissioning(state) do
    if network_ready_for_remote_access?(state.settings) do
      case Configuration.mark_commissioned() do
        :ok -> %{state | settings: Map.put(state.settings, :commissioned, true)}
        {:error, _reason} -> schedule_commissioning_retry(state)
      end
    else
      schedule_commissioning_retry(state)
    end
  end

  defp network_ready_for_remote_access?(settings) do
    status = PlcRemote.NetworkManager.status()
    Commissioning.network_ready?(settings, status)
  catch
    :exit, _reason -> false
  end

  defp schedule_commissioning_retry(state) do
    Process.send_after(self(), :complete_commissioning, @commission_retry_ms)
    state
  end

  defp connection_failed(state, reason) do
    failure_count = state.failure_count + 1
    retry_delay = RetryPolicy.delay(failure_count)

    Logger.warning(
      "Tailscale PLC proxy unavailable: #{inspect(reason)}; " <>
        "retrying in #{div(retry_delay, 1_000)} seconds"
    )

    state = stop_connection(state)
    retry_timer = Process.send_after(self(), :retry_connection, retry_delay)

    %{
      state
      | state: :error,
        reason: inspect(reason),
        retry_timer: retry_timer,
        retry_at: System.monotonic_time(:millisecond) + retry_delay,
        failure_count: failure_count,
        connected_since: nil
    }
  end

  defp stop_connection(state) do
    terminate_task(state.connect_task)
    terminate_task(state.listener_task)
    terminate_proxy_sessions()
    cancel_timer(state.connect_timer)
    cancel_timer(state.retry_timer)

    %{
      state
      | device: nil,
        listener: nil,
        connect_task: nil,
        listener_task: nil,
        connect_timer: nil,
        retry_timer: nil,
        retry_at: nil,
        tailnet_ipv4: nil
    }
  end

  defp terminate_proxy_sessions do
    terminate_supervised_tasks(PlcRemote.TailscaleSessionTaskSupervisor)
  end

  defp terminate_supervised_tasks(supervisor) do
    supervisor
    |> Task.Supervisor.children()
    |> Enum.each(&Task.Supervisor.terminate_child(supervisor, &1))
  catch
    :exit, _reason -> :ok
  end

  defp terminate_task(nil), do: :ok

  defp terminate_task(%Task{pid: pid}) do
    _result =
      Task.Supervisor.terminate_child(PlcRemote.TailscaleConnectionTaskSupervisor, pid)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp active_session_count do
    PlcRemote.TailscaleSessionTaskSupervisor
    |> Task.Supervisor.children()
    |> length()
  catch
    :exit, _reason -> 0
  end

  defp elapsed_seconds(nil), do: nil

  defp elapsed_seconds(since) do
    max(div(System.monotonic_time(:millisecond) - since, 1_000), 0)
  end

  defp retry_in_seconds(nil), do: nil

  defp retry_in_seconds(retry_at) do
    max(div(retry_at - System.monotonic_time(:millisecond), 1_000), 0)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _result = Process.cancel_timer(timer)
    :ok
  end

  defp task_reference(nil), do: nil
  defp task_reference(%Task{ref: reference}), do: reference

  defp connection_settings(settings) do
    {settings.tailscale, settings.machine.plc_address, settings.uplink}
  end

  defp destination(settings) do
    "#{settings.machine.plc_address}:#{settings.tailscale.destination_port}"
  end

  defp format_remote({address, port}), do: "#{format_ip(address)}:#{port}"
  defp format_remote(other), do: inspect(other)

  defp format_ip(address), do: address |> :inet.ntoa() |> to_string()
end
