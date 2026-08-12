defmodule PlcRemote.Recovery do
  @moduledoc "Public API for event-driven staged remote-access recovery."

  alias PlcRemote.Recovery.{Runtime, Status}

  @spec status() :: Status.t()
  defdelegate status(), to: Runtime

  @spec reset_reboot_budget() :: :ok | {:error, term()}
  defdelegate reset_reboot_budget(), to: Runtime
end
