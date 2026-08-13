defmodule PlcRemote.Events.ServiceChanged do
  @moduledoc "The local service WLAN lifecycle changed."

  @enforce_keys [:status]
  defstruct [:status]

  @type t :: %__MODULE__{status: PlcRemote.Service.Status.t()}
end
