defmodule PlcRemoteTest do
  use ExUnit.Case, async: true

  test "exposes the isolated machine and uplink roles" do
    assert PlcRemote.network_roles() == %{
             machine_lan: nil,
             recovery: "usb0",
             wifi_uplink: "wlan0",
             wired_uplink: nil
           }
  end
end
