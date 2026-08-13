defmodule PlcRemote.Tailscale.Enrollment do
  @moduledoc "A transient, validated Tailscale authentication credential."

  @enforce_keys [:auth_key]
  defstruct @enforce_keys

  @type t :: %__MODULE__{auth_key: String.t()}

  @spec new(String.t()) :: {:ok, t()} | {:error, :missing_auth_key | :invalid_auth_key}
  def new(auth_key) when is_binary(auth_key) do
    auth_key = String.trim(auth_key)

    cond do
      auth_key == "" ->
        {:error, :missing_auth_key}

      Regex.match?(~r/^tskey-auth-[A-Za-z0-9_-]{8,}$/, auth_key) ->
        {:ok, %__MODULE__{auth_key: auth_key}}

      true ->
        {:error, :invalid_auth_key}
    end
  end

  def new(_auth_key), do: {:error, :missing_auth_key}

  @doc false
  @spec consume(t()) :: String.t()
  def consume(%__MODULE__{auth_key: auth_key}), do: auth_key

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(_enrollment, _opts), do: concat(["#PlcRemote.Tailscale.Enrollment<[FILTERED]>"])
  end
end
