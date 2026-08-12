defmodule PlcRemote.Panel do
  @moduledoc "Public read API for IPCBOX local indicators and isolated digital I/O."

  @spec status() :: PlcRemote.Panel.Status.t()
  defdelegate status(), to: PlcRemote.Panel.Runtime
end
