defmodule PlcRemote.Service.GPIOState do
  @moduledoc false

  defstruct handle: nil,
            subscription_ref: nil,
            error: nil,
            asserted?: false,
            hold_timer: nil

  @type t :: %__MODULE__{
          handle: term() | nil,
          subscription_ref: term() | nil,
          error: PlcRemote.Error.t() | nil,
          asserted?: boolean(),
          hold_timer: reference() | nil
        }
end
