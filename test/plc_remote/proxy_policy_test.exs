defmodule PlcRemote.ProxyPolicyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.{ProxyPolicy, Settings}

  test "opens the fixed proxy only with an enabled and resolved PLC Ethernet role" do
    disabled = Settings.defaults(service_psk: "commissioning-key")
    healthy = %{last_error: nil, roles: %{machine_lan: "eth0"}}
    assert ProxyPolicy.machine_ifname(disabled, healthy) == nil

    enabled = put_in(disabled.machine.enabled, true)

    assert ProxyPolicy.machine_ifname(enabled, %{last_error: nil, roles: %{machine_lan: nil}}) ==
             nil

    assert ProxyPolicy.machine_ifname(enabled, healthy) == "eth0"

    failed = %{healthy | last_error: "PLC interface failed to apply"}
    assert ProxyPolicy.machine_ifname(enabled, failed) == nil
  end
end
