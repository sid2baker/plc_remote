defmodule PlcRemote.Recovery.PolicyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Recovery.Policy

  @thresholds %{
    reconnect: 10,
    reapply_network: 20,
    cycle_uplink: 30,
    restart_tailscale: 40,
    reboot: 50
  }

  test "escalates from least disruptive action to reboot" do
    completed = MapSet.new()
    assert Policy.next_action(9, completed, @thresholds) == nil
    assert Policy.next_action(50, completed, @thresholds) == :reconnect

    completed = MapSet.put(completed, :reconnect)
    assert Policy.next_action(50, completed, @thresholds) == :reapply_network

    completed = MapSet.put(completed, :reapply_network)
    assert Policy.next_action(50, completed, @thresholds) == :cycle_uplink

    completed = MapSet.put(completed, :cycle_uplink)
    assert Policy.next_action(50, completed, @thresholds) == :restart_tailscale

    completed = MapSet.put(completed, :restart_tailscale)
    assert Policy.next_action(50, completed, @thresholds) == :reboot
  end
end
