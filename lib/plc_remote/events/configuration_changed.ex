defmodule PlcRemote.Events.ConfigurationChanged do
  @moduledoc "A validated persistent configuration revision was published."

  @enforce_keys [:revision]
  defstruct [:revision]

  @type t :: %__MODULE__{revision: non_neg_integer()}
end
