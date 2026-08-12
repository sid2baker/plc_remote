defmodule PlcRemote.Events.PanelChanged do
  @moduledoc "The IPCBOX panel input/output observation changed."

  @enforce_keys [:status]
  defstruct [:status]

  @type t :: %__MODULE__{status: PlcRemote.Panel.Status.t()}
end
