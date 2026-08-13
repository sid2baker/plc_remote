defmodule PlcRemote.Service.State do
  @moduledoc false

  alias PlcRemote.Service.{GPIOState, Portal}

  @enforce_keys [:runtime, :settings]
  defstruct runtime: nil,
            settings: nil,
            portal: %Portal{},
            gpio: %GPIOState{},
            ssid: nil,
            routing: :inactive,
            last_error: nil

  @type t :: %__MODULE__{
          runtime: pid(),
          settings: PlcRemote.Settings.t(),
          portal: Portal.t(),
          gpio: GPIOState.t(),
          ssid: String.t() | nil,
          routing: :inactive | :active | :unavailable,
          last_error: PlcRemote.Error.t() | nil
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(state, opts) do
      safe = %{
        gpio_error: state.gpio.error,
        last_error: state.last_error,
        portal_active: is_pid(state.portal.pid),
        routing: state.routing,
        ssid: state.ssid
      }

      concat(["#PlcRemote.Service.State<", to_doc(safe, opts), ">"])
    end
  end
end
