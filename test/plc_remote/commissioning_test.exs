defmodule PlcRemote.CommissioningTest do
  use ExUnit.Case, async: true

  alias PlcRemote.{Commissioning, Settings}

  test "requires commissioning until final verification persists success" do
    refute Settings.defaults(service_psk: "commissioning-key").commissioned
    assert Commissioning.required?(Settings.defaults(service_psk: "commissioning-key"))
    refute Commissioning.required?(%{Settings.defaults() | commissioned: true})
  end

  test "requires an assigned Ethernet Internet role without requiring a PLC role" do
    settings =
      Settings.defaults(service_psk: "commissioning-key")
      |> put_in([:uplink, :mode], :ethernet)

    ready = %{last_error: nil, roles: %{machine_lan: nil, internet_uplink: "eth0"}}

    assert Commissioning.network_ready?(settings, ready)
    refute Commissioning.network_ready?(settings, put_in(ready.roles.internet_uplink, nil))
    refute Commissioning.network_ready?(settings, %{ready | last_error: "failed"})
  end

  test "verification requires only Internet and a joined tailnet" do
    checks =
      Commissioning.verification(
        %{connection: :internet},
        %{state: :connected, tailnet_ipv4: "100.64.0.1"}
      )

    assert checks == %{internet: true, tailscale: true}
    assert Commissioning.verified?(checks)
    refute Commissioning.verified?(%{checks | internet: false})
  end
end
