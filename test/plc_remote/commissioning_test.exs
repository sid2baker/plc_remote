defmodule PlcRemote.CommissioningTest do
  use ExUnit.Case, async: true

  alias PlcRemote.{Commissioning, Settings}

  test "requires commissioning until the persisted marker is set" do
    settings = Settings.defaults(service_psk: "commissioning-key")
    assert Commissioning.required?(settings)
    refute Commissioning.required?(%{settings | commissioned: true})
  end

  test "requires distinct resolved machine and wired-uplink roles without network errors" do
    settings = Settings.defaults(service_psk: "commissioning-key")
    settings = put_in(settings.uplink.mode, :ethernet)

    ready = %{
      last_error: nil,
      roles: %{machine_lan: "eth0", wired_uplink: "eth1"}
    }

    assert Commissioning.network_ready?(settings, ready)
    refute Commissioning.network_ready?(settings, put_in(ready.roles.machine_lan, nil))
    refute Commissioning.network_ready?(settings, %{ready | last_error: "configuration failed"})
  end
end
