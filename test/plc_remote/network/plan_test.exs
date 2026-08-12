defmodule PlcRemote.Network.PlanTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Network.Plan
  alias PlcRemote.Settings

  @interfaces [
    %{ifname: "eth0", hw_path: "/devices/wan", kind: :ethernet},
    %{ifname: "eth1", hw_path: "/devices/plc", kind: :ethernet},
    %{ifname: "eth2", hw_path: "/devices/unassigned", kind: :ethernet},
    %{ifname: "wlan0", hw_path: "/devices/wifi", kind: :wifi}
  ]

  test "always includes a complete disable baseline before valid role configurations" do
    settings =
      Settings.defaults()
      |> put_in([:uplink, :mode], :ethernet)
      |> put_in([:uplink, :ethernet, :interface_hw_path], "/devices/wan")
      |> put_in([:machine, :enabled], true)
      |> put_in([:machine, :interface_hw_path], "/devices/plc")

    plan = Plan.build(settings, @interfaces)

    assert Enum.map(plan.disable, &elem(&1, 0)) == ["eth0", "eth1", "eth2"]
    assert Enum.map(plan.enable, &elem(&1, 0)) == ["eth1", "eth0"]
    assert Enum.all?(plan.disable, fn {_ifname, config} -> config.ipv4.method == :disabled end)

    {_ifname, plc_config} = Enum.find(plan.enable, &(elem(&1, 0) == "eth1"))
    refute Map.has_key?(plc_config.ipv4, :gateway)
    refute Map.has_key?(plc_config.ipv4, :name_servers)
  end

  test "keeps the complete disable baseline when role resolution fails" do
    settings = put_in(Settings.defaults().uplink.mode, :ethernet)
    plan = Plan.build(settings, @interfaces)

    assert plan.enable == []
    assert plan.error == {:interface_unassigned, :internet_uplink}
    assert [_first, _second, _third] = plan.disable
  end
end
