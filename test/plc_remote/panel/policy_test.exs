defmodule PlcRemote.Panel.PolicyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Panel.Policy

  test "defaults all external outputs off and reports no fault LEDs" do
    assert Policy.levels(nil, %{lifecycle: :disabled}, nil) == %{
             output_1: 0,
             output_2: 0,
             user_1: 1,
             user_2: 1
           }
  end

  test "OUT1 requires the complete applied PLC listener path" do
    network = %{applied: true, last_error: nil, roles: %{machine_lan: "eth1"}}
    tailscale = %{lifecycle: :connected, listener: :active}

    assert Policy.levels(network, tailscale, nil).output_1 == 1
    assert Policy.levels(%{network | applied: false}, tailscale, nil).output_1 == 0
    assert Policy.levels(network, %{tailscale | listener: :inactive}, nil).output_1 == 0
  end

  test "OUT2 follows service AP activity and USER LEDs are active low faults" do
    service = %{active: true, lifecycle: :recovery, gpio_error: nil}
    tailscale = %{lifecycle: :retry_wait, listener: :unavailable}

    levels = Policy.levels(nil, tailscale, service)
    assert levels.output_2 == 1
    assert levels.user_1 == 0
    assert levels.user_2 == 1

    fault = %{service | active: false, lifecycle: :fault}
    assert Policy.levels(nil, tailscale, fault).user_2 == 0
  end
end
