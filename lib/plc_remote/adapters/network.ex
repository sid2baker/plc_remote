defmodule PlcRemote.Adapters.Network do
  @moduledoc false

  @type interface_info :: %{
          required(:ifname) => PlcRemote.Network.ifname(),
          required(:hw_path) => String.t(),
          required(:kind) => :ethernet | :wifi | :recovery | :other,
          optional(:driver) => String.t() | nil,
          optional(:speed_mbps) => pos_integer() | nil,
          optional(:lower_up) => boolean() | nil,
          optional(:connection) => :disconnected | :lan | :internet | nil,
          optional(:mac_address) => String.t() | nil
        }

  @callback configure(PlcRemote.Network.ifname(), map(), keyword()) :: :ok | {:error, term()}
  @callback wait_for_address(PlcRemote.Network.ifname(), String.t(), timeout()) ::
              :ok | {:error, term()}
  @callback connection_status() :: :disconnected | :lan | :internet | nil
  @callback interfaces() :: [interface_info()]
end
