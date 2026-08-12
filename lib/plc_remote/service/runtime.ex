defmodule PlcRemote.Service.Runtime do
  @moduledoc "Translates GPIO, portal, configuration, verification, and timeout facts into Service FSM events."

  use GenServer

  require Logger

  alias PlcRemote.Events.{ConfigurationChanged, ServiceChanged}
  alias PlcRemote.Service.{Actions, GPIO, State, Status, Verification}

  @fsm_name PlcRemote.Service.FSM
  @verification_check_ms 2_000
  @verification_timeout_ms 180_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec activate() :: :ok | {:error, term()}
  def activate, do: GenServer.call(__MODULE__, :activate, 30_000)

  @spec deactivate() :: :ok | {:error, term()}
  def deactivate, do: GenServer.call(__MODULE__, :deactivate, 30_000)

  @spec finish_commissioning() :: {:ok, :verifying} | {:error, term()}
  def finish_commissioning, do: GenServer.call(__MODULE__, :finish_commissioning, 30_000)

  @spec touch() :: :ok
  def touch, do: GenServer.cast(__MODULE__, :touch)

  @spec status() :: Status.t()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl GenServer
  def init(_opts) do
    :ok = PlcRemote.Events.subscribe()
    settings = PlcRemote.Configuration.current()
    gpio = GPIO.open(settings.service)
    payload = %State{runtime: self(), settings: settings, gpio: gpio}
    {:ok, _pid} = PlcRemote.Service.FSM.start_link(payload: payload, name: @fsm_name)

    state = %{
      retry_timer: nil,
      timeout_timer: nil,
      verification_timer: nil,
      hold_timer: nil,
      published_status: nil
    }

    state = start_initial_service(state, settings)
    PlcRemote.Clock.send_after(self(), :publish_status, 0)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, current_status(), state}

  def handle_call(:activate, _from, state) do
    case lifecycle() do
      lifecycle when lifecycle in [:verifying_automatic, :verifying_recovery] ->
        {:reply, {:error, :verification_in_progress}, state}

      :inactive ->
        transition(:activate_requested, nil)
        {:reply, wait_for_lifecycle([:recovery, :fault]), reschedule(state)}

      :fault ->
        transition(:retry_recovery, nil)
        {:reply, wait_for_lifecycle([:recovery, :fault]), reschedule(state)}

      _active ->
        {:reply, :ok, reset_timeout(state)}
    end
  end

  def handle_call(:deactivate, _from, state) do
    case lifecycle() do
      :automatic ->
        {:reply, {:error, :commissioning_required}, state}

      lifecycle when lifecycle in [:verifying_automatic, :verifying_recovery] ->
        {:reply, {:error, :verification_in_progress}, state}

      :inactive ->
        {:reply, :ok, state}

      _active ->
        transition(:deactivate_requested, nil)
        reply = wait_for_lifecycle([:inactive])
        {:reply, reply, cancel_runtime_timers(state)}
    end
  end

  def handle_call(:finish_commissioning, _from, state) do
    case lifecycle() do
      lifecycle when lifecycle in [:verifying_automatic, :verifying_recovery] ->
        {:reply, {:ok, :verifying}, state}

      lifecycle when lifecycle in [:automatic, :recovery] ->
        transition(:finish_requested, nil)
        PlcRemote.Clock.send_after(self(), :begin_verification, 750)
        {:reply, {:ok, :verifying}, reschedule(state)}

      _other ->
        {:reply, {:error, :automatic_commissioning_not_active}, state}
    end
  end

  @impl GenServer
  def handle_cast(:touch, state), do: {:noreply, reset_timeout(state)}

  @impl GenServer
  def handle_info(%ConfigurationChanged{}, state) do
    settings = PlcRemote.Configuration.current()
    payload = current_payload()

    gpio_changed? =
      settings.service.gpio_spec != payload.settings.service.gpio_spec or
        settings.service.active_level != payload.settings.service.active_level

    gpio =
      if gpio_changed? do
        GPIO.close(payload.gpio)
        GPIO.open(settings.service)
      else
        payload.gpio
      end

    transition(:refresh, %{payload | settings: settings, gpio: gpio})

    state =
      if automatic_required?(settings) and lifecycle() in [:inactive, :fault] do
        schedule_retry(state, :automatic, 0)
      else
        reset_timeout(state)
      end

    {:noreply, reschedule(state)}
  end

  def handle_info({:circuits_gpio, %{ref: reference, value: value}}, state) do
    payload = current_payload()
    gpio = GPIO.update(payload.gpio, payload.settings.service, reference, value)
    transition(:refresh, %{payload | gpio: gpio})
    {:noreply, update_hold_timer(state, gpio.asserted?)}
  end

  def handle_info(:gpio_hold_complete, state) do
    state = %{state | hold_timer: nil}

    if GPIO.asserted?(current_payload().gpio) and lifecycle() in [:inactive, :fault] do
      event = if lifecycle() == :fault, do: :retry_recovery, else: :activate_requested
      transition(event, nil)
    end

    {:noreply, reschedule(state)}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    payload = current_payload()

    if payload.portal.monitor_ref == reference do
      crashed_lifecycle = lifecycle()
      error = %PlcRemote.Error{subsystem: :service, operation: :portal, reason: reason}
      transition(:portal_stopped, error)

      retry_mode =
        if crashed_lifecycle in [:automatic, :verifying_automatic],
          do: :automatic,
          else: :recovery

      {:noreply, schedule_retry(cancel_runtime_timers(state), retry_mode)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:begin_verification, state) do
    case lifecycle() do
      lifecycle when lifecycle in [:verifying_automatic, :verifying_recovery] ->
        Logger.info("Verifying Ethernet Internet and Tailscale before closing the setup AP")
        deadline = PlcRemote.Clock.now_ms() + verification_timeout_ms()
        payload = current_payload()
        transition(:refresh, %{payload | verification_deadline: deadline})
        {:noreply, state |> cancel_timeout_timer() |> schedule_verification(0)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:verify_commissioning, state) do
    state = %{state | verification_timer: nil}
    payload = current_payload()

    case Verification.evaluate(PlcRemote.Health.snapshot(), payload.settings) do
      :ok ->
        checks = %{internet: true, tailscale: true}
        transition(:verification_succeeded, checks)
        {:noreply, cancel_runtime_timers(state) |> reschedule()}

      {:wait, checks} ->
        transition(:refresh, %{payload | verification: Verification.running(checks)})

        if PlcRemote.Clock.now_ms() >= payload.verification_deadline do
          Logger.warning("Final commissioning verification failed; setup AP remains active")
          transition(:verification_failed, {checks, :verification_timeout})
          {:noreply, reset_timeout(state) |> reschedule()}
        else
          {:noreply, schedule_verification(state)}
        end
    end
  end

  def handle_info(:service_timeout, state) do
    Logger.info("Service mode timed out; disabling the service access point")
    transition(:deactivate_requested, nil)
    {:noreply, cancel_runtime_timers(state) |> reschedule()}
  end

  def handle_info({:retry_service, mode}, state) do
    state = %{state | retry_timer: nil}
    event = if mode == :automatic, do: :retry_automatic, else: :retry_recovery

    event =
      if lifecycle() == :inactive and mode == :automatic, do: :commissioning_required, else: event

    event =
      if lifecycle() == :inactive and mode == :recovery, do: :activate_requested, else: event

    transition(event, nil)
    {:noreply, reschedule(state)}
  end

  def handle_info(:publish_status, state), do: {:noreply, publish_status(state)}
  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cancel_runtime_timers(state)

    if Process.whereis(@fsm_name) do
      GPIO.close(current_payload().gpio)
    end

    :ok
  end

  defp start_initial_service(state, settings) do
    cond do
      automatic_required?(settings) ->
        schedule_retry(state, :automatic, 0)

      settings.commissioned and Actions.initial_intent() == :recovery ->
        schedule_retry(state, :recovery, 0)

      true ->
        Actions.clear_intent()
        state
    end
  end

  defp current_status do
    payload = current_payload()
    lifecycle = lifecycle()

    %Status{
      lifecycle: lifecycle,
      active: is_pid(payload.portal.pid),
      address: payload.settings.service.address,
      expires_in_seconds: expires_in_seconds(payload.expires_at),
      gpio_error: payload.gpio.error,
      gpio_spec: payload.settings.service.gpio_spec,
      secured: lifecycle in [:recovery, :verifying_recovery],
      ssid: payload.ssid,
      verification: payload.verification
    }
  end

  defp publish_status(state) do
    status = current_status()

    if status != state.published_status do
      PlcRemote.Events.publish(%ServiceChanged{status: status})
    end

    state = %{state | published_status: status}
    if status.lifecycle == :fault, do: schedule_retry(state, retry_mode(status)), else: state
  end

  defp retry_mode(_status) do
    case Actions.initial_intent() do
      :automatic -> :automatic
      _other -> :recovery
    end
  end

  defp wait_for_lifecycle(expected, attempts \\ 100)
  defp wait_for_lifecycle(_expected, 0), do: {:error, :service_transition_timeout}

  defp wait_for_lifecycle(expected, attempts) do
    lifecycle = lifecycle()

    if lifecycle in expected do
      if lifecycle == :fault, do: {:error, current_payload().last_error}, else: :ok
    else
      Process.sleep(5)
      wait_for_lifecycle(expected, attempts - 1)
    end
  end

  defp automatic_required?(settings) do
    Application.get_env(:plc_remote, :auto_commissioning, true) and not settings.commissioned
  end

  defp update_hold_timer(state, true) do
    if lifecycle() in [:inactive, :fault] and is_nil(state.hold_timer) do
      %{
        state
        | hold_timer:
            PlcRemote.Clock.send_after(
              self(),
              :gpio_hold_complete,
              current_payload().settings.service.hold_ms
            )
      }
    else
      state
    end
  end

  defp update_hold_timer(state, false) do
    cancel_timer(state.hold_timer)
    %{state | hold_timer: nil}
  end

  defp reset_timeout(state) do
    lifecycle = lifecycle()

    if lifecycle in [:recovery] do
      state = cancel_timeout_timer(state)
      timeout_ms = current_payload().settings.service.timeout_ms
      expires_at = PlcRemote.Clock.now_ms() + timeout_ms
      transition(:refresh, %{current_payload() | expires_at: expires_at})
      %{state | timeout_timer: PlcRemote.Clock.send_after(self(), :service_timeout, timeout_ms)}
    else
      state
    end
  end

  defp schedule_retry(state, mode, delay \\ 5_000) do
    if is_reference(state.retry_timer) do
      state
    else
      %{state | retry_timer: PlcRemote.Clock.send_after(self(), {:retry_service, mode}, delay)}
    end
  end

  defp schedule_verification(state, delay \\ nil) do
    delay = delay || verification_check_ms()

    %{
      state
      | verification_timer: PlcRemote.Clock.send_after(self(), :verify_commissioning, delay)
    }
  end

  defp cancel_runtime_timers(state) do
    Enum.each(
      [state.retry_timer, state.timeout_timer, state.verification_timer, state.hold_timer],
      &cancel_timer/1
    )

    %{state | retry_timer: nil, timeout_timer: nil, verification_timer: nil, hold_timer: nil}
  end

  defp cancel_timeout_timer(state) do
    cancel_timer(state.timeout_timer)
    %{state | timeout_timer: nil}
  end

  defp reschedule(state) do
    PlcRemote.Clock.send_after(self(), :publish_status, 0)
    state
  end

  defp transition(event, payload), do: PlcRemote.FSM.transition(@fsm_name, event, payload)
  defp current_payload, do: PlcRemote.FSM.payload(@fsm_name)
  defp lifecycle, do: PlcRemote.FSM.lifecycle(@fsm_name)

  defp expires_in_seconds(nil), do: nil
  defp expires_in_seconds(at), do: max(div(at - PlcRemote.Clock.now_ms(), 1_000), 0)

  defp verification_check_ms,
    do:
      Application.get_env(
        :plc_remote,
        :commissioning_verification_check_ms,
        @verification_check_ms
      )

  defp verification_timeout_ms,
    do:
      Application.get_env(
        :plc_remote,
        :commissioning_verification_timeout_ms,
        @verification_timeout_ms
      )

  defp cancel_timer(timer), do: PlcRemote.FSM.cancel_timer(timer)
end
