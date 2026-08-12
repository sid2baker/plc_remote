defmodule PlcRemote.Events.FirmwareChanged do
  @moduledoc "The active firmware lifecycle or validation evidence changed."

  @enforce_keys [:status]
  defstruct [:status]

  @type t :: %__MODULE__{status: PlcRemote.Firmware.Status.t()}
end
