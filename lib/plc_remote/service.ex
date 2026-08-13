defmodule PlcRemote.Service do
  @moduledoc "Public API for the service-switch controlled local WLAN."

  alias PlcRemote.Service.{Runtime, Status}

  @spec recheck() :: :ok
  defdelegate recheck(), to: Runtime

  @spec status() :: Status.t()
  defdelegate status(), to: Runtime

  @spec active?() :: boolean()
  def active?, do: status().active
end
