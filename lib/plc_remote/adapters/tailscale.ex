defmodule PlcRemote.Adapters.Tailscale do
  @moduledoc false

  @callback validate_enrollment(PlcRemote.Settings.t(), String.t()) ::
              {:ok, term(), :inet.ip4_address()} | {:error, term()}
  @callback commit_enrollment(term()) :: {:ok, term()} | {:error, term()}
  @callback finalize_enrollment(term()) :: :ok | {:error, term()}
  @callback rollback_enrollment(term()) :: :ok | {:error, term()}
  @callback discard_enrollment(term()) :: :ok
  @callback connect(PlcRemote.Settings.t(), String.t() | nil, keyword()) ::
              {:ok, term(), term() | nil, :inet.ip4_address()} | {:error, term()}
  @callback accept(term()) :: {:ok, term()} | {:error, term()}
  @callback remote_address(term()) :: {:inet.ip_address(), :inet.port_number()} | term()
  @callback recv(term()) :: {:ok, binary()} | {:error, term()}
  @callback send_all(term(), binary()) :: :ok | {:error, term()}
end
