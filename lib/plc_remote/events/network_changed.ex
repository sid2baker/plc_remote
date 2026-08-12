defmodule PlcRemote.Events.NetworkChanged do
  @moduledoc "The applied network roles or Internet observation changed."

  @enforce_keys [:status]
  defstruct [:status]

  @type t :: %__MODULE__{status: PlcRemote.Network.Status.t()}
end
