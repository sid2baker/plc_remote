defmodule PlcRemote.Adapters.GPIO do
  @moduledoc false

  @callback open_input(String.t()) :: {:ok, term(), term()} | {:error, term()}
  @callback read(term()) :: 0 | 1 | {:error, term()}
  @callback open_output(String.t(), 0 | 1) :: {:ok, term()} | {:error, term()}
  @callback write(term(), 0 | 1) :: :ok | {:error, term()}
  @callback close(term()) :: :ok
end
