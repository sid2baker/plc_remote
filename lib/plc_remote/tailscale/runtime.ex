defmodule PlcRemote.Tailscale.Runtime do
  @moduledoc """
  Translates typed domain events, timers, and task results into Tailscale FSM events.

  The runtime owns no lifecycle decision. `Tailscale.FSM` is the sole lifecycle
  source of truth.
  """

  use GenServer

  alias PlcRemote.Events.{ConfigurationChanged, NetworkChanged, TailscaleChanged}
  alias PlcRemote.Tailscale.{Enrollment, State, Status}

  @fsm_name PlcRemote.Tailscale.FSM
  @connect_timeout_ms 60_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec status() :: Status.t()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec enroll(Enrollment.t()) :: :ok
  def enroll(%Enrollment{} = enrollment), do: GenServer.call(__MODULE__, {:enroll, enrollment})

  @spec reconnect() :: :ok
  def reconnect, do: GenServer.cast(__MODULE__, :reconnect)

  @impl GenServer
  def init(opts) do
    :ok = PlcRemote.Events.subscribe()

    payload = %State{
      adapter: Application.fetch_env!(:plc_remote, :tailscale_adapter),
      runtime: self(),
      settings: PlcRemote.Configuration.current(),
      network: Keyword.fetch!(opts, :network)
    }

    {:ok, _pid} = PlcRemote.Tailscale.FSM.start_link(payload: payload, name: @fsm_name)
    transition(:evaluate, nil)
    PlcRemote.Clock.send_after(self(), :publish_status, 0)

    {:ok, %{connect_timer: nil, retry_timer: nil, published_status: nil}}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, current_status(), state}

  def handle_call({:enroll, %Enrollment{} = enrollment}, _from, state) do
    auth_key = Enrollment.consume(enrollment)
    payload = current_payload()
    transition(:evaluate, %{payload | pending_auth_key: auth_key, failure_count: 0})
    {:reply, :ok, reschedule(state)}
  end

  @impl GenServer
  def handle_cast(:reconnect, state) do
    event = if lifecycle() == :connected, do: :reconnect, else: :evaluate
    transition(event, nil)
    {:noreply, reschedule(state)}
  end

  @impl GenServer
  def handle_info(%ConfigurationChanged{}, state) do
    settings = PlcRemote.Configuration.current()
    payload = current_payload()
    reset? = connection_settings(payload.settings) != connection_settings(settings)

    transition(:evaluate, %{
      payload
      | settings: settings,
        failure_count: if(reset?, do: 0, else: payload.failure_count)
    })

    {:noreply, reschedule(state)}
  end

  def handle_info(%NetworkChanged{status: network}, state) do
    transition(:evaluate, %{current_payload() | network: network})
    {:noreply, reschedule(state)}
  end

  def handle_info({:tailscale_connect_result, pid, {:ok, device, listener, ipv4}}, state) do
    if current_payload().connect_task == pid do
      transition(:connected, {pid, device, listener, ipv4})
      {:noreply, state |> cancel_connect_timer() |> reschedule()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tailscale_connect_result, pid, {:error, reason}}, state) do
    if current_payload().connect_task == pid do
      transition(:failed, {:connect, pid, reason})
      {:noreply, state |> cancel_connect_timer() |> reschedule()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tailscale_listener_result, pid, result}, state) do
    if current_payload().listener_task == pid do
      transition(:failed, {pid, result})
      {:noreply, reschedule(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:connect_timeout, state) do
    transition(:failed, :connection_timeout)
    {:noreply, state |> Map.put(:connect_timer, nil) |> reschedule()}
  end

  def handle_info(:retry_connection, state) do
    transition(:evaluate, nil)
    {:noreply, state |> Map.put(:retry_timer, nil) |> reschedule()}
  end

  def handle_info(:publish_status, state) do
    {:noreply, publish_status(state)}
  end

  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cancel_timer(state.connect_timer)
    cancel_timer(state.retry_timer)
    :ok
  end

  defp reschedule(state) do
    PlcRemote.Clock.send_after(self(), :publish_status, 0)
    state
  end

  defp publish_status(state) do
    status = current_status()
    state = schedule_lifecycle_timer(state, status)

    if status != state.published_status do
      PlcRemote.Events.publish(%TailscaleChanged{status: status})
    end

    %{state | published_status: status}
  end

  defp schedule_lifecycle_timer(state, %Status{lifecycle: :connecting}) do
    state = cancel_retry_timer(state)

    if is_reference(state.connect_timer) do
      state
    else
      %{
        state
        | connect_timer: PlcRemote.Clock.send_after(self(), :connect_timeout, @connect_timeout_ms)
      }
    end
  end

  defp schedule_lifecycle_timer(state, %Status{lifecycle: :retry_wait} = status) do
    state = cancel_connect_timer(state)

    if is_reference(state.retry_timer) do
      state
    else
      delay = max((status.retry_in_seconds || 0) * 1_000, 1)
      %{state | retry_timer: PlcRemote.Clock.send_after(self(), :retry_connection, delay)}
    end
  end

  defp schedule_lifecycle_timer(state, _status) do
    state |> cancel_connect_timer() |> cancel_retry_timer()
  end

  defp current_status do
    case fsm_state() do
      %Finitomata.State{current: lifecycle, payload: %State{} = payload} ->
        settings = payload.settings

        %Status{
          lifecycle: lifecycle,
          listener: listener_status(lifecycle, payload),
          active_sessions: PlcRemote.Tailscale.Actions.active_session_count(),
          connected_for_seconds: elapsed_seconds(payload.connected_since),
          destination: "#{settings.machine.plc_address}:#{settings.tailscale.destination_port}",
          failure_count: payload.failure_count,
          listen_port: settings.tailscale.listen_port,
          last_error: payload.last_error,
          retry_in_seconds: retry_in_seconds(payload.retry_at),
          tailnet_ipv4: payload.tailnet_ipv4
        }
    end
  end

  defp listener_status(:connected, %State{listener: listener}) when not is_nil(listener),
    do: :active

  defp listener_status(:connected, %State{settings: %{machine: %{enabled: false}}}), do: :disabled
  defp listener_status(:connected, _payload), do: :inactive
  defp listener_status(_lifecycle, %State{settings: %{machine: %{enabled: false}}}), do: :disabled
  defp listener_status(_lifecycle, _payload), do: :unavailable

  defp current_payload, do: PlcRemote.FSM.payload(@fsm_name)
  defp transition(event, payload), do: PlcRemote.FSM.transition(@fsm_name, event, payload)
  defp fsm_state, do: PlcRemote.FSM.state(@fsm_name)
  defp lifecycle, do: PlcRemote.FSM.lifecycle(@fsm_name)

  defp connection_settings(settings) do
    {settings.tailscale, settings.machine, settings.uplink.mode, settings.uplink.ethernet}
  end

  defp elapsed_seconds(nil), do: nil

  defp elapsed_seconds(since) do
    max(div(PlcRemote.Clock.now_ms() - since, 1_000), 0)
  end

  defp retry_in_seconds(nil), do: nil

  defp retry_in_seconds(retry_at) do
    max(div(retry_at - PlcRemote.Clock.now_ms(), 1_000), 0)
  end

  defp cancel_connect_timer(state) do
    cancel_timer(state.connect_timer)
    %{state | connect_timer: nil}
  end

  defp cancel_retry_timer(state) do
    cancel_timer(state.retry_timer)
    %{state | retry_timer: nil}
  end

  defp cancel_timer(timer), do: PlcRemote.FSM.cancel_timer(timer)
end
