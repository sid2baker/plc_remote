defmodule PlcRemote.Integration.GPIO do
  @moduledoc false

  @behaviour PlcRemote.Adapters.GPIO

  @impl true
  def open(_gpio_spec), do: {:error, :emulated_gpio_unavailable}

  @impl true
  def read(_gpio), do: 1

  @impl true
  def close(_gpio), do: :ok
end
