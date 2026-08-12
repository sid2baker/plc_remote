defmodule PlcRemote.Service do
  @moduledoc "Public API for setup and physically enabled recovery access."

  alias PlcRemote.Service.{Runtime, Status}

  @spec activate() :: :ok | {:error, term()}
  defdelegate activate(), to: Runtime

  @spec deactivate() :: :ok | {:error, term()}
  defdelegate deactivate(), to: Runtime

  @spec finish_commissioning() :: {:ok, :verifying} | {:error, term()}
  defdelegate finish_commissioning(), to: Runtime

  @spec touch() :: :ok
  defdelegate touch(), to: Runtime

  @spec status() :: Status.t()
  defdelegate status(), to: Runtime

  @spec active?() :: boolean()
  def active?, do: status().lifecycle != :inactive
end
