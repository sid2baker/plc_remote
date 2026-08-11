defmodule PlcRemote.Adapters.GPIO do
  @moduledoc false

  @callback open(String.t()) :: {:ok, term(), term()} | {:error, term()}
  @callback read(term()) :: 0 | 1
  @callback close(term()) :: :ok
end
