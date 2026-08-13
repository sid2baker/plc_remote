defmodule PlcRemote.Service.GPIO do
  @moduledoc "Owns service-switch GPIO adaptation and primitive GPIO health."

  require Logger

  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.ServiceGPIOUnavailable
  alias PlcRemote.Service.GPIOState

  @spec open(map()) :: GPIOState.t()
  def open(service_settings) do
    case adapter().open_input(service_settings.gpio_spec) do
      {:ok, handle, reference} -> open_gpio(handle, reference, service_settings.active_level)
      {:error, :not_available_on_host} -> unavailable_on_host()
      {:error, reason} -> open_failed(reason)
    end
  end

  defp open_gpio(handle, reference, active_level) do
    case adapter().read(handle) do
      value when value in [0, 1] ->
        Alarm.clear(ServiceGPIOUnavailable)

        %GPIOState{
          handle: handle,
          subscription_ref: reference,
          asserted?: value == active_level
        }

      {:error, reason} ->
        close_failed_open(handle, :read, reason)

      reason ->
        close_failed_open(handle, :read, reason)
    end
  end

  defp unavailable_on_host do
    Alarm.clear(ServiceGPIOUnavailable)
    %GPIOState{error: error(:open, :not_available_on_host)}
  end

  defp open_failed(reason) do
    error = error(:open, reason)
    Logger.error("Unable to monitor service GPIO: #{inspect(reason)}")
    Alarm.set(ServiceGPIOUnavailable, error)
    %GPIOState{error: error}
  end

  @spec close(GPIOState.t()) :: :ok
  def close(%GPIOState{handle: nil}), do: :ok

  def close(%GPIOState{handle: handle}) do
    result = adapter().close(handle)
    Alarm.clear(ServiceGPIOUnavailable)
    result
  end

  @spec update(GPIOState.t(), map(), term(), 0 | 1) :: GPIOState.t()
  def update(%GPIOState{subscription_ref: reference} = gpio, settings, reference, value) do
    %{gpio | asserted?: value == settings.active_level}
  end

  def update(%GPIOState{} = gpio, _settings, _reference, _value), do: gpio

  @spec switch_state(GPIOState.t()) :: boolean() | :unknown
  def switch_state(%GPIOState{handle: nil}), do: :unknown

  def switch_state(%GPIOState{handle: handle} = gpio) do
    case adapter().read(handle) do
      value when value in [0, 1] -> gpio.asserted?
      _error -> :unknown
    end
  catch
    _kind, _reason -> :unknown
  end

  @spec asserted?(GPIOState.t()) :: boolean()
  def asserted?(gpio), do: switch_state(gpio) == true

  @spec deasserted?(GPIOState.t()) :: boolean()
  def deasserted?(gpio), do: switch_state(gpio) == false

  defp close_failed_open(handle, operation, reason) do
    _result = adapter().close(handle)
    error = error(operation, reason)
    Logger.error("Unable to read service GPIO: #{inspect(reason)}")
    Alarm.set(ServiceGPIOUnavailable, error)
    %GPIOState{error: error}
  end

  defp error(operation, reason) do
    %PlcRemote.Error{subsystem: :service_gpio, operation: operation, reason: reason}
  end

  defp adapter, do: Application.fetch_env!(:plc_remote, :gpio_adapter)
end
