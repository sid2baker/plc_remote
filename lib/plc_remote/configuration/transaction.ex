defmodule PlcRemote.Configuration.Transaction do
  @moduledoc "Explicit onsite configuration transaction boundary."

  @spec begin() :: :ok | {:error, term()}
  defdelegate begin(), to: PlcRemote.Configuration, as: :begin_service_transaction

  @spec commit() :: :ok | {:error, term()}
  defdelegate commit(), to: PlcRemote.Configuration, as: :commit_service_transaction

  @spec rollback() :: :ok | {:error, term()}
  defdelegate rollback(), to: PlcRemote.Configuration, as: :rollback_service_transaction
end
