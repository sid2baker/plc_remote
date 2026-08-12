defmodule PlcRemote.Tailscale.Enrollment do
  @moduledoc """
  A transient Tailscale credential accepted only by the enrollment command.

  This value must never be persisted, published, included in alarms or public
  status, or logged.
  """

  @enforce_keys [:auth_key]
  defstruct @enforce_keys

  @type t :: %__MODULE__{auth_key: String.t()}

  @spec new(String.t()) :: t()
  def new(auth_key) when is_binary(auth_key) and auth_key != "" do
    %__MODULE__{auth_key: auth_key}
  end

  @doc false
  @spec consume(t()) :: String.t()
  def consume(%__MODULE__{auth_key: auth_key}), do: auth_key

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(_enrollment, _opts), do: concat(["#PlcRemote.Tailscale.Enrollment<[FILTERED]>"])
  end
end
