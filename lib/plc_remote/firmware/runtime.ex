defmodule PlcRemote.Firmware.Runtime do
  @moduledoc "Consumes typed health events and drives conservative candidate firmware decisions."

  use GenServer

  alias PlcRemote.Events.{
    ConfigurationChanged,
    FirmwareChanged,
    NetworkChanged,
    ServiceChanged,
    TailscaleChanged
  }

  alias PlcRemote.Firmware.{ExpectationStore, Policy, State, Status}

  @fsm_name PlcRemote.Firmware.FSM
  @tailnet_stable_ms 60_000
  @regression_ms 2_700_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec status() :: Status.t()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec prepare_update() :: :ok | {:error, term()}
  def prepare_update, do: GenServer.call(__MODULE__, :prepare_update)

  @impl GenServer
  def init(_opts) do
    :ok = PlcRemote.Events.subscribe()
    adapter = system_adapter()
    :ok = adapter.init_complete()
    validation = adapter.firmware_validation_status()
    path = Application.get_env(:plc_remote, :update_expectation_path)
    remote_expected? = validation == :unvalidated and ExpectationStore.load(path)
    if validation != :unvalidated, do: ExpectationStore.clear(path)

    payload = %State{
      runtime: self(),
      settings: PlcRemote.Configuration.current(),
      expectation_path: path,
      validation: validation,
      remote_expected: remote_expected?
    }

    {:ok, _pid} = PlcRemote.Firmware.FSM.start_link(payload: payload, name: @fsm_name)
    transition(initial_event(validation), nil)
    PlcRemote.Clock.send_after(self(), :publish_status, 0)
    send(self(), :evaluate)
    {:ok, %{decision_timer: nil}}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, current_status(), state}

  def handle_call(:prepare_update, _from, state) do
    cond do
      lifecycle() != :validated ->
        {:reply, {:error, :firmware_not_validated}, state}

      not current_payload().settings.tailscale.enabled or
          PlcRemote.Health.snapshot().tailscale != :connected ->
        {:reply, {:error, :tailscale_not_connected}, state}

      true ->
        transition(:prepare_update, nil)
        Process.sleep(5)

        case current_payload().last_error do
          nil -> {:reply, :ok, state}
          error -> {:reply, {:error, error.reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_info(%ConfigurationChanged{}, state) do
    settings = PlcRemote.Configuration.current()
    transition(:refresh, %{current_payload() | settings: settings})
    send(self(), :evaluate)
    {:noreply, state}
  end

  def handle_info(%NetworkChanged{}, state) do
    transition(:refresh, %{current_payload() | network_observed: true})
    send(self(), :evaluate)
    {:noreply, state}
  end

  def handle_info(%event{}, state) when event in [TailscaleChanged, ServiceChanged] do
    send(self(), :evaluate)
    {:noreply, state}
  end

  def handle_info(:publish_status, state) do
    PlcRemote.Events.publish(%FirmwareChanged{status: current_status()})
    {:noreply, state}
  end

  def handle_info(:evaluate, state) do
    state = cancel_decision_timer(state)

    if lifecycle() == :candidate do
      now = PlcRemote.Clock.now_ms()
      payload = update_evidence(current_payload(), PlcRemote.Health.snapshot(), now)
      transition(:evidence_changed, payload)
      decision = decision(payload, now)

      case decision do
        :validate -> transition(:validate, validation_reason(payload))
        :revert -> transition(:revert, nil)
        :wait -> :ok
      end

      PlcRemote.Clock.send_after(self(), :publish_status, 0)
      {:noreply, schedule_decision(state, payload, now)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cancel_timer(state.decision_timer)
    :ok
  end

  defp decision(%{settings: %{commissioned: false}} = payload, _now) do
    health = PlcRemote.Health.snapshot()
    if payload.network_observed and health.service_access == :active, do: :validate, else: :wait
  end

  defp decision(payload, now) do
    health = PlcRemote.Health.snapshot()

    if not payload.settings.tailscale.enabled and payload.network_observed and
         health.internet == :available do
      :validate
    else
      commissioned_decision(payload, health, now)
    end
  end

  defp commissioned_decision(payload, health, now) do
    Policy.commissioned(
      %{state: if(health.tailscale == :connected, do: :connected, else: :unavailable)},
      %{connection: if(health.internet == :available, do: :internet, else: :disconnected)},
      elapsed_ms(payload.tailnet_stable_since, now),
      elapsed_ms(payload.internet_without_tail_since, now),
      elapsed_ms(payload.candidate_unreachable_since, now),
      tailnet_stable_ms: tailnet_stable_ms(),
      internet_without_tail_ms: regression_ms(),
      remote_expected: payload.remote_expected,
      candidate_unreachable_ms: regression_ms()
    )
  end

  defp update_evidence(payload, health, now) do
    cond do
      health.tailscale == :connected ->
        %{
          payload
          | tailnet_stable_since: payload.tailnet_stable_since || now,
            internet_without_tail_since: nil,
            candidate_unreachable_since: nil
        }

      health.internet == :available ->
        %{
          payload
          | tailnet_stable_since: nil,
            internet_without_tail_since: payload.internet_without_tail_since || now,
            candidate_unreachable_since: payload.candidate_unreachable_since || now
        }

      true ->
        %{
          payload
          | tailnet_stable_since: nil,
            internet_without_tail_since: nil,
            candidate_unreachable_since:
              if(payload.remote_expected,
                do: payload.candidate_unreachable_since || now,
                else: nil
              )
        }
    end
  end

  defp schedule_decision(state, payload, now) do
    deadlines =
      [
        deadline(payload.tailnet_stable_since, tailnet_stable_ms()),
        deadline(payload.internet_without_tail_since, regression_ms()),
        deadline(payload.candidate_unreachable_since, regression_ms())
      ]
      |> Enum.reject(&is_nil/1)

    case deadlines do
      [] ->
        state

      deadlines ->
        %{
          state
          | decision_timer:
              PlcRemote.Clock.send_after(self(), :evaluate, max(Enum.min(deadlines) - now, 1))
        }
    end
  end

  defp validation_reason(%{settings: %{commissioned: false}}),
    do: "service WLAN is healthy and network hardware was observed"

  defp validation_reason(%{settings: %{tailscale: %{enabled: false}}}),
    do: "Tailscale is intentionally disabled and Ethernet health is available"

  defp validation_reason(_payload), do: "tailnet connectivity remained stable"

  defp current_status do
    payload = current_payload()
    now = PlcRemote.Clock.now_ms()

    %Status{
      lifecycle: lifecycle(),
      validation: payload.validation,
      candidate_unreachable_seconds: elapsed_seconds(payload.candidate_unreachable_since, now),
      internet_without_tail_seconds: elapsed_seconds(payload.internet_without_tail_since, now),
      last_action: payload.last_action,
      last_error: payload.last_error,
      remote_expected: payload.remote_expected,
      tailnet_stable_seconds: elapsed_seconds(payload.tailnet_stable_since, now)
    }
  end

  defp initial_event(:validated), do: :initialized_validated
  defp initial_event(:unvalidated), do: :initialized_candidate
  defp initial_event(:unknown), do: :initialized_unknown
  defp deadline(nil, _duration), do: nil
  defp deadline(since, duration), do: since + duration
  defp elapsed_ms(nil, _now), do: nil
  defp elapsed_ms(since, now), do: now - since
  defp elapsed_seconds(nil, _now), do: nil
  defp elapsed_seconds(since, now), do: div(now - since, 1_000)

  defp cancel_decision_timer(state) do
    cancel_timer(state.decision_timer)
    %{state | decision_timer: nil}
  end

  defp transition(event, payload), do: PlcRemote.FSM.transition(@fsm_name, event, payload)
  defp current_payload, do: PlcRemote.FSM.payload(@fsm_name)
  defp lifecycle, do: PlcRemote.FSM.lifecycle(@fsm_name)

  defp tailnet_stable_ms,
    do: Application.get_env(:plc_remote, :firmware_tailnet_stable_ms, @tailnet_stable_ms)

  defp regression_ms,
    do:
      Application.get_env(:plc_remote, :firmware_internet_without_tail_revert_ms, @regression_ms)

  defp cancel_timer(timer), do: PlcRemote.FSM.cancel_timer(timer)
  defp system_adapter, do: Application.fetch_env!(:plc_remote, :system_adapter)
end
