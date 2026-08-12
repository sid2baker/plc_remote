defmodule PlcRemote.Events.TailscaleChanged do
  @moduledoc "The Tailscale lifecycle or fixed-listener observation changed."

  @enforce_keys [:status]
  defstruct [:status]

  @type t :: %__MODULE__{status: PlcRemote.Tailscale.Status.t()}
end
