defmodule PlcRemote.Adapters.Tailscale do
  @moduledoc false

  @callback connect(PlcRemote.Settings.t(), String.t() | nil) ::
              {:ok, term(), term(), :inet.ip4_address()} | {:error, term()}
  @callback accept(term()) :: {:ok, term()} | {:error, term()}
  @callback remote_address(term()) :: {:inet.ip_address(), :inet.port_number()} | term()
  @callback recv(term()) :: {:ok, binary()} | {:error, term()}
  @callback send_all(term(), binary()) :: :ok | {:error, term()}
end
