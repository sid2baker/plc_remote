defmodule PlcRemote.Service.Portal do
  @moduledoc false

  defstruct pid: nil, monitor_ref: nil

  @type t :: %__MODULE__{pid: pid() | nil, monitor_ref: reference() | nil}
end
