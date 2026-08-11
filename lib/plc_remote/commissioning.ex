defmodule PlcRemote.Commissioning do
  @moduledoc """
  Pure rules for first-boot commissioning.

  Keeping these decisions outside the network, web, and Tailscale processes
  makes the security boundary explicit: an open setup WLAN is required until a
  successful tailnet connection has a usable machine role, a usable uplink
  role, and an error-free network configuration.
  """

  @doc "Returns whether automatic first-boot commissioning is still required."
  @spec required?(PlcRemote.Settings.t()) :: boolean()
  def required?(settings), do: not settings.commissioned

  @doc "Returns whether network roles are safe to mark as commissioned."
  @spec network_ready?(PlcRemote.Settings.t(), map()) :: boolean()
  def network_ready?(settings, network_status) do
    is_nil(network_status.last_error) and
      not is_nil(network_status.roles.machine_lan) and
      uplink_ready?(settings.uplink.mode, network_status.roles)
  end

  defp uplink_ready?(:wifi, _roles), do: true

  defp uplink_ready?(mode, roles) when mode in [:auto, :ethernet],
    do: not is_nil(roles.wired_uplink)

  defp uplink_ready?(_mode, _roles), do: false
end
