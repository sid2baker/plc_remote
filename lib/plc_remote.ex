defmodule PlcRemote do
  @moduledoc """
  Remote-access gateway firmware for industrial PLC networks.

  The gateway keeps the PLC LAN separate from its Ethernet Internet uplink and
  exposes one configured PLC TCP endpoint through a Tailscale userspace proxy.
  """

  @doc "Returns current interface names for the configured network roles."
  @spec network_roles() :: %{PlcRemote.Network.role() => PlcRemote.Network.ifname() | nil}
  def network_roles, do: PlcRemote.NetworkManager.status().roles
end
