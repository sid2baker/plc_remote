defmodule PlcRemote.Service.Runtime do
  @moduledoc "Keeps the WPA2 service WLAN aligned directly with IPCBOX IN1."

  use GenServer

  alias PlcRemote.Events.{ConfigurationChanged, NetworkChanged, ServiceChanged}
  alias PlcRemote.Service.{GPIO, State, Status}

  @fsm_name PlcRemote.Service.FSM
  @debounce_ms 150
  @retry_ms 5_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec status() :: Status.t()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec recheck() :: :ok
  def recheck, do: GenServer.cast(__MODULE__, :recheck)

  @impl GenServer
  def init(_opts) do
    :ok = PlcRemote.Events.subscribe()
    settings = PlcRemote.Configuration.current()
    gpio = GPIO.open(settings.service)
    payload = %State{runtime: self(), settings: settings, gpio: gpio}
    {:ok, _pid} = PlcRemote.Service.FSM.start_link(payload: payload, name: @fsm_name)

    state = %{debounce_timer: nil, retry_timer: nil, published_status: nil}
    send(self(), :apply_switch)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, current_status(), state}

  @impl GenServer
  def handle_cast(:recheck, state) do
    {:noreply, schedule_switch(state, 0)}
  end

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
    {:noreply, schedule_switch(state, 0)}
  end

  def handle_info(%NetworkChanged{}, state) do
    if lifecycle() == :active do
      payload = current_payload()
      routing = routing_status(PlcRemote.Service.Router.enable())
      transition(:refresh, %{payload | routing: routing})
    end

    {:noreply, state |> publish_status() |> publish_and_retry()}
  end

  def handle_info({:circuits_gpio, %{ref: reference, value: value}}, state)
      when value in [0, 1] do
    payload = current_payload()
    gpio = GPIO.update(payload.gpio, payload.settings.service, reference, value)
    transition(:refresh, %{payload | gpio: gpio})
    {:noreply, schedule_switch(state, @debounce_ms)}
  end

  def handle_info({:circuits_gpio, _invalid_event}, state) do
    {:noreply, schedule_switch(state, @debounce_ms)}
  end

  def handle_info(:apply_switch, state) do
    state = %{state | debounce_timer: nil, retry_timer: nil}
    desired = desired_state(current_payload().gpio)
    apply_desired(desired)
    {:noreply, publish_and_retry(state)}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    payload = current_payload()

    if payload.portal.monitor_ref == reference do
      error = %PlcRemote.Error{subsystem: :service, operation: :portal, reason: reason}
      transition(:failed, error)
      {:noreply, publish_and_retry(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cancel_timer(state.debounce_timer)
    cancel_timer(state.retry_timer)

    if Process.whereis(@fsm_name), do: GPIO.close(current_payload().gpio)
    :ok
  end

  defp routing_status(:ok), do: :active
  defp routing_status({:error, _reason}), do: :unavailable

  defp apply_desired(:active) do
    if lifecycle() != :active, do: transition(:enable, current_payload())
  end

  defp apply_desired(:inactive) do
    if lifecycle() != :inactive, do: transition(:disable, nil)
  end

  # Fail open for local service: only a confirmed high signal may disable the AP.
  defp desired_state(gpio) do
    if GPIO.deasserted?(gpio), do: :inactive, else: :active
  end

  defp current_status do
    payload = current_payload()
    lifecycle = lifecycle()

    %Status{
      lifecycle: lifecycle,
      active: lifecycle == :active and is_pid(payload.portal.pid),
      address: payload.settings.service.address,
      gpio_asserted: GPIO.switch_state(payload.gpio),
      gpio_error: payload.gpio.error,
      gpio_spec: payload.settings.service.gpio_spec,
      routing: payload.routing,
      secured: true,
      ssid: payload.ssid
    }
  end

  defp publish_and_retry(state) do
    state = publish_status(state)

    if lifecycle() == :fault and desired_state(current_payload().gpio) == :active do
      schedule_retry(state)
    else
      cancel_retry(state)
    end
  end

  defp publish_status(state) do
    status = current_status()

    if status != state.published_status,
      do: PlcRemote.Events.publish(%ServiceChanged{status: status})

    %{state | published_status: status}
  end

  defp schedule_switch(state, delay) do
    cancel_timer(state.debounce_timer)
    %{state | debounce_timer: PlcRemote.Clock.send_after(self(), :apply_switch, delay)}
  end

  defp schedule_retry(%{retry_timer: timer} = state) when is_reference(timer), do: state

  defp schedule_retry(state) do
    %{state | retry_timer: PlcRemote.Clock.send_after(self(), :apply_switch, @retry_ms)}
  end

  defp cancel_retry(state) do
    cancel_timer(state.retry_timer)
    %{state | retry_timer: nil}
  end

  defp transition(event, payload) do
    PlcRemote.FSM.transition(@fsm_name, event, payload)
  end

  defp current_payload, do: PlcRemote.FSM.payload(@fsm_name)
  defp lifecycle, do: PlcRemote.FSM.lifecycle(@fsm_name)

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: :ok
end
