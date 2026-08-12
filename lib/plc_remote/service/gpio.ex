defmodule PlcRemote.Service.GPIO do
  @moduledoc "Owns recovery GPIO adaptation and primitive GPIO health."

  require Logger

  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.ServiceGPIOUnavailable
  alias PlcRemote.Service.GPIOState

  @spec open(map()) :: GPIOState.t()
  def open(service_settings) do
    case adapter().open(service_settings.gpio_spec) do
      {:ok, handle, reference} ->
        asserted? = adapter().read(handle) == service_settings.active_level
        Alarm.clear(ServiceGPIOUnavailable)
        %GPIOState{handle: handle, subscription_ref: reference, asserted?: asserted?}

      {:error, :not_available_on_host} ->
        error = error(:open, :not_available_on_host)
        Alarm.clear(ServiceGPIOUnavailable)
        %GPIOState{error: error}

      {:error, reason} ->
        error = error(:open, reason)
        Logger.error("Unable to monitor service GPIO: #{inspect(reason)}")
        Alarm.set(ServiceGPIOUnavailable, error)
        %GPIOState{error: error}
    end
  end

  @spec close(GPIOState.t()) :: :ok
  def close(%GPIOState{handle: nil}), do: :ok

  def close(%GPIOState{handle: handle}) do
    adapter().close(handle)
    Alarm.clear(ServiceGPIOUnavailable)
  end

  @spec update(GPIOState.t(), map(), term(), 0 | 1) :: GPIOState.t()
  def update(%GPIOState{subscription_ref: reference} = gpio, settings, reference, value) do
    %{gpio | asserted?: value == settings.active_level}
  end

  def update(%GPIOState{} = gpio, _settings, _reference, _value), do: gpio

  @spec asserted?(GPIOState.t()) :: boolean()
  def asserted?(%GPIOState{handle: nil}), do: false

  def asserted?(%GPIOState{handle: handle} = gpio) do
    adapter().read(handle)
    gpio.asserted?
  catch
    _kind, _reason -> false
  end

  defp error(operation, reason) do
    %PlcRemote.Error{subsystem: :service_gpio, operation: operation, reason: reason}
  end

  defp adapter, do: Application.fetch_env!(:plc_remote, :gpio_adapter)
end
