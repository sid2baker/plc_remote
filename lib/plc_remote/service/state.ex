defmodule PlcRemote.Service.State do
  @moduledoc false

  alias PlcRemote.Service.{GPIOState, Portal, Verification}

  @enforce_keys [:runtime, :settings]
  defstruct runtime: nil,
            settings: nil,
            portal: %Portal{},
            gpio: %GPIOState{},
            ssid: nil,
            expires_at: nil,
            verification_deadline: nil,
            verification: %Verification{},
            last_error: nil

  @type t :: %__MODULE__{
          runtime: pid(),
          settings: PlcRemote.Settings.t(),
          portal: Portal.t(),
          gpio: GPIOState.t(),
          ssid: String.t() | nil,
          expires_at: integer() | nil,
          verification_deadline: integer() | nil,
          verification: Verification.t(),
          last_error: PlcRemote.Error.t() | nil
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(state, opts) do
      safe = %{
        expires_at: state.expires_at,
        gpio_error: state.gpio.error,
        last_error: state.last_error,
        portal_active: is_pid(state.portal.pid),
        ssid: state.ssid,
        verification: state.verification,
        verification_deadline: state.verification_deadline
      }

      concat(["#PlcRemote.Service.State<", to_doc(safe, opts), ">"])
    end
  end
end
