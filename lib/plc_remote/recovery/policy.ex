defmodule PlcRemote.Recovery.Policy do
  @moduledoc """
  Pure escalation ordering for loss of remote access.

  Actions are intentionally least disruptive first. Even after a long scheduler
  pause, the policy performs each missing stage in order rather than jumping
  directly to a reboot.
  """

  @type action :: :reconnect | :reapply_network | :cycle_uplinks | :restart_tailscale | :reboot
  @actions [:reconnect, :reapply_network, :cycle_uplinks, :restart_tailscale, :reboot]

  @doc "Returns the next due action, or `nil` when no new action is due."
  @spec next_action(non_neg_integer(), MapSet.t(action()), %{action() => non_neg_integer()}) ::
          action() | nil
  def next_action(elapsed_ms, completed, thresholds) do
    Enum.find(@actions, fn action ->
      elapsed_ms >= Map.fetch!(thresholds, action) and not MapSet.member?(completed, action)
    end)
  end
end
