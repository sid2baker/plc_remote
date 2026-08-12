defmodule PlcRemote.Firmware do
  @moduledoc "Public API for conservative A/B firmware candidate validation."

  alias PlcRemote.Firmware.{Runtime, Status}

  @spec status() :: Status.t()
  defdelegate status(), to: Runtime

  @spec prepare_update() :: :ok | {:error, term()}
  defdelegate prepare_update(), to: Runtime
end
