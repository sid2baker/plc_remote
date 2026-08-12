defmodule PlcRemote.Panel.Status do
  @moduledoc "Non-secret status for the IPCBOX local panel and isolated digital I/O."

  @type availability :: :available | :unavailable | :not_configured
  @type input_state :: :active | :inactive | :unavailable
  @type output_state :: :on | :off | :unavailable

  @enforce_keys [
    :available,
    :input_2,
    :output_1,
    :output_2,
    :user_1,
    :user_2,
    :last_error
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          available: availability(),
          input_2: input_state(),
          output_1: output_state(),
          output_2: output_state(),
          user_1: output_state(),
          user_2: output_state(),
          last_error: PlcRemote.Error.t() | nil
        }
end
