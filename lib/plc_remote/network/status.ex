defmodule PlcRemote.Network.Status do
  @moduledoc "Non-secret operational status for the physical network runtime."

  @type connection :: :internet | :lan | :disconnected | atom()
  @type roles :: %{PlcRemote.Network.role() => PlcRemote.Network.ifname() | nil}

  @enforce_keys [
    :applied,
    :applied_at,
    :connection,
    :interfaces,
    :last_error,
    :roles,
    :uplink_mode
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          applied: boolean(),
          applied_at: DateTime.t() | nil,
          connection: connection(),
          interfaces: [PlcRemote.Adapters.Network.interface_info()],
          last_error: term() | nil,
          roles: roles(),
          uplink_mode: :disabled | :ethernet
        }
end
