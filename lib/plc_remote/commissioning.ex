defmodule PlcRemote.Commissioning do
  @moduledoc """
  Pure first-boot commissioning rules.

  The setup AP remains available until an installer explicitly proves Internet
  over the selected Ethernet port and a joined Tailscale identity.
  """

  @doc "Returns whether automatic first-boot commissioning is still required."
  @spec required?(PlcRemote.Settings.t()) :: boolean()
  def required?(settings), do: not settings.commissioned

  @doc "Returns whether the configured Ethernet Internet interface is ready to test."
  @spec network_ready?(PlcRemote.Settings.t(), map()) :: boolean()
  def network_ready?(settings, network_status) do
    settings.uplink.mode == :ethernet and
      is_nil(network_status.last_error) and
      not is_nil(network_status.roles.internet_uplink)
  end

  @doc "Builds the non-secret checklist used by the final commissioning transaction."
  @spec verification(map(), map()) :: map()
  def verification(network, tailscale) do
    %{
      internet: network.connection == :internet,
      tailscale:
        tailscale.state == :connected and is_binary(tailscale.tailnet_ipv4) and
          tailscale.tailnet_ipv4 != ""
    }
  end

  @doc "Returns whether every required final commissioning check passed."
  @spec verified?(map()) :: boolean()
  def verified?(checks) do
    Enum.all?([:internet, :tailscale], &Map.get(checks, &1, false))
  end
end
