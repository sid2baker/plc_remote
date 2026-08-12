defmodule PlcRemote.Adapters.Target.GPIO do
  @moduledoc false

  @behaviour PlcRemote.Adapters.GPIO

  @impl true
  def open(gpio_spec) do
    with {:ok, gpio} <- gpio_call(:open, [gpio_spec, :input]),
         {:ok, reference} <- gpio_call(:subscribe, [gpio]) do
      {:ok, gpio, reference}
    end
  end

  @impl true
  def read(gpio), do: gpio_call(:read, [gpio])

  @impl true
  def close(gpio), do: gpio_call(:close, [gpio])

  # The x86_64 integration firmware substitutes its own adapter and deliberately
  # omits the native Circuits.GPIO dependency.
  defp gpio_call(function, arguments), do: apply(Circuits.GPIO, function, arguments)
end
