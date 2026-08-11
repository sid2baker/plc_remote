defmodule PlcRemote.FirmwareValidator do
  @moduledoc """
  Validates tentative A/B firmware using product-level health checks.

  A commissioned image is validated only after Tailscale remains connected.
  If ordinary Internet works but the new image cannot restore Tailscale within
  the rollback window, the previous firmware is selected. An external Internet
  outage never triggers rollback: the candidate remains running and
  unvalidated, so a later power cycle can still fall back safely.
  """

  use GenServer

  require Logger

  alias PlcRemote.Firmware.{ExpectationStore, Policy}

  @check_interval_ms 10_000
  @tailnet_stable_ms 60_000
  @internet_without_tail_revert_ms 2_700_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns firmware validation progress without changing slot state."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Records proven remote connectivity immediately before an OTA update."
  @spec prepare_for_update() :: :ok | {:error, term()}
  def prepare_for_update, do: GenServer.call(__MODULE__, :prepare_for_update)

  @impl GenServer
  def init(_opts) do
    adapter = system_adapter()
    :ok = adapter.init_complete()
    validation_status = adapter.firmware_validation_status()
    expectation_path = Application.get_env(:plc_remote, :update_expectation_path)

    remote_expected? =
      validation_status == :unvalidated and ExpectationStore.load(expectation_path)

    if validation_status != :unvalidated, do: ExpectationStore.clear(expectation_path)
    schedule_check(0)

    {:ok,
     %{
       validation_status: validation_status,
       expectation_path: expectation_path,
       remote_expected: remote_expected?,
       tailnet_stable_since: nil,
       internet_without_tail_since: nil,
       candidate_unreachable_since: nil,
       last_action: nil,
       last_error: nil,
       revert_requested: false
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    now = now_ms()

    status = %{
      candidate_unreachable_seconds: elapsed_seconds(state.candidate_unreachable_since, now),
      firmware: state.validation_status,
      internet_without_tail_seconds: elapsed_seconds(state.internet_without_tail_since, now),
      last_action: state.last_action,
      last_error: state.last_error,
      remote_expected: state.remote_expected,
      tailnet_stable_seconds: elapsed_seconds(state.tailnet_stable_since, now)
    }

    {:reply, status, state}
  end

  def handle_call(:prepare_for_update, _from, state) do
    tailscale = safe_status(PlcRemote.TailscaleManager)

    cond do
      state.validation_status != :validated ->
        {:reply, {:error, :firmware_not_validated}, state}

      tailscale[:state] != :connected ->
        {:reply, {:error, :tailscale_not_connected}, state}

      true ->
        case ExpectationStore.mark(state.expectation_path) do
          :ok -> {:reply, :ok, %{state | remote_expected: true}}
          {:error, reason} = error -> {:reply, error, %{state | last_error: inspect(reason)}}
        end
    end
  end

  @impl GenServer
  def handle_info(:check_firmware, state) do
    state = evaluate(state, now_ms())
    schedule_check()
    {:noreply, state}
  end

  defp evaluate(%{validation_status: status} = state, _now)
       when status in [:validated, :unknown],
       do: state

  defp evaluate(%{revert_requested: true} = state, _now), do: state

  defp evaluate(state, now) do
    settings = PlcRemote.Configuration.get()

    if settings.commissioned do
      evaluate_commissioned(state, now, settings)
    else
      evaluate_uncommissioned(state)
    end
  end

  defp evaluate_uncommissioned(state) do
    case PlcRemote.ServiceMode |> safe_status() |> Policy.uncommissioned() do
      :validate -> validate(state, "automatic commissioning WLAN is healthy")
      :wait -> state
    end
  end

  defp evaluate_commissioned(state, _now, %{tailscale: %{enabled: false}}) do
    network = safe_status(PlcRemote.NetworkManager)

    if not is_nil(network[:applied_at]) and is_nil(network[:last_error]) do
      validate(state, "Tailscale is intentionally disabled and local networking is healthy")
    else
      state
    end
  end

  defp evaluate_commissioned(state, now, _settings) do
    tailscale = safe_status(PlcRemote.TailscaleManager)
    network = safe_status(PlcRemote.NetworkManager)
    state = update_connectivity_evidence(state, tailscale, network, now)

    decision =
      Policy.commissioned(
        tailscale,
        network,
        elapsed_ms(state.tailnet_stable_since, now),
        elapsed_ms(state.internet_without_tail_since, now),
        elapsed_ms(state.candidate_unreachable_since, now),
        tailnet_stable_ms: tailnet_stable_ms(),
        internet_without_tail_ms: internet_revert_ms(),
        remote_expected: state.remote_expected,
        candidate_unreachable_ms: internet_revert_ms()
      )

    case decision do
      :validate -> validate(state, "tailnet connectivity remained stable")
      :revert -> revert(state)
      :wait -> state
    end
  end

  defp update_connectivity_evidence(state, tailscale, network, now) do
    cond do
      tailscale[:state] == :connected ->
        %{
          state
          | tailnet_stable_since: state.tailnet_stable_since || now,
            internet_without_tail_since: nil,
            candidate_unreachable_since: nil
        }

      network[:connection] == :internet ->
        %{
          state
          | internet_without_tail_since: state.internet_without_tail_since || now,
            candidate_unreachable_since: state.candidate_unreachable_since || now,
            tailnet_stable_since: nil
        }

      true ->
        %{
          state
          | tailnet_stable_since: nil,
            internet_without_tail_since: nil,
            candidate_unreachable_since:
              if(state.remote_expected, do: state.candidate_unreachable_since || now, else: nil)
        }
    end
  end

  defp validate(state, reason) do
    Logger.info("Validating candidate firmware: #{reason}")

    case system_adapter().validate_firmware() do
      :ok ->
        Logger.info("Candidate firmware validated successfully")
        _result = ExpectationStore.clear(state.expectation_path)

        %{
          state
          | validation_status: :validated,
            remote_expected: false,
            last_action: :validated,
            last_error: nil
        }

      {:error, reason} ->
        Logger.error("Unable to validate candidate firmware: #{inspect(reason)}")
        %{state | last_error: inspect(reason)}
    end
  end

  defp revert(state) do
    Logger.error(
      "Candidate firmware has Internet but cannot restore Tailscale; reverting to previous slot"
    )

    case system_adapter().revert_firmware() do
      :ok -> %{state | revert_requested: true, last_action: :revert_requested, last_error: nil}
      {:error, reason} -> %{state | last_error: inspect(reason)}
    end
  end

  defp safe_status(module) do
    module.status()
  catch
    :exit, _reason -> %{}
  end

  defp tailnet_stable_ms do
    Application.get_env(:plc_remote, :firmware_tailnet_stable_ms, @tailnet_stable_ms)
  end

  defp internet_revert_ms do
    Application.get_env(
      :plc_remote,
      :firmware_internet_without_tail_revert_ms,
      @internet_without_tail_revert_ms
    )
  end

  defp elapsed_ms(nil, _now), do: nil
  defp elapsed_ms(since, now), do: now - since

  defp elapsed_seconds(since, now) do
    case elapsed_ms(since, now) do
      nil -> nil
      elapsed -> div(elapsed, 1_000)
    end
  end

  defp schedule_check(delay \\ @check_interval_ms) do
    Process.send_after(self(), :check_firmware, delay)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp system_adapter, do: Application.fetch_env!(:plc_remote, :system_adapter)
end
