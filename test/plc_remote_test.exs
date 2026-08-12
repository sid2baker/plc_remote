defmodule PlcRemoteTest do
  use ExUnit.Case, async: true

  test "sets the tailscale-rs acknowledgement before native code loads" do
    vm_args = File.read!(Path.expand("../rel/vm.args.eex", __DIR__))
    assert vm_args =~ "-env TS_RS_EXPERIMENT this_is_unstable_software"
  end

  test "exposes the isolated machine and uplink roles" do
    assert PlcRemote.network_roles() == %{
             internet_uplink: nil,
             machine_lan: nil,
             recovery: "usb0",
             service_ap: "wlan0"
           }
  end
end
