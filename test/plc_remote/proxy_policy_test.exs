defmodule PlcRemote.ProxyPolicyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Proxy.Policy
  alias PlcRemote.Settings

  test "opens the fixed proxy only with an enabled and resolved PLC Ethernet role" do
    disabled = Settings.defaults(service_psk: "commissioning-key")
    healthy = %{applied: true, last_error: nil, roles: %{machine_lan: "eth0"}}
    assert Policy.machine_ifname(disabled, healthy) == nil

    enabled = put_in(disabled.machine.enabled, true)

    assert Policy.machine_ifname(enabled, %{
             applied: true,
             last_error: nil,
             roles: %{machine_lan: nil}
           }) == nil

    assert Policy.machine_ifname(enabled, healthy) == "eth0"
    assert Policy.machine_ifname(enabled, %{healthy | applied: false}) == nil

    failed = %{healthy | last_error: "PLC interface failed to apply"}
    assert Policy.machine_ifname(enabled, failed) == nil
  end
end
