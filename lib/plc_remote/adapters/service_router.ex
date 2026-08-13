defmodule PlcRemote.Adapters.ServiceRouter do
  @moduledoc false

  @callback enable(String.t(), String.t()) :: :ok | {:error, term()}
  @callback disable() :: :ok | {:error, term()}
end
