defmodule PlcRemote.Error do
  @moduledoc "Structured internal operation failure; stringify only at presentation boundaries."

  @enforce_keys [:subsystem, :operation, :reason]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          subsystem: atom(),
          operation: atom(),
          reason: term()
        }
end
