defmodule PlcRemote.Adapters.Target.GPIO do
  @moduledoc false

  @behaviour PlcRemote.Adapters.GPIO

  @impl true
  def open(gpio_spec) do
    with {:ok, gpio} <- Circuits.GPIO.open(gpio_spec, :input),
         {:ok, reference} <- Circuits.GPIO.subscribe(gpio) do
      {:ok, gpio, reference}
    end
  end

  @impl true
  def read(gpio), do: Circuits.GPIO.read(gpio)

  @impl true
  def close(gpio), do: Circuits.GPIO.close(gpio)
end
