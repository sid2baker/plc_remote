defmodule PlcRemote.NetworkTest do
  use ExUnit.Case, async: true

  alias PlcRemote.{Network, Settings}

  test "machine LAN configuration is static and has no Internet route" do
    config = Network.machine_lan_config("192.168.10.2", 24)

    assert config == %{
             type: VintageNetEthernet,
             ipv4: %{
               method: :static,
               address: {192, 168, 10, 2},
               prefix_length: 24
             }
           }

    refute Map.has_key?(config.ipv4, :gateway)
    refute Map.has_key?(config.ipv4, :name_servers)
  end

  test "rejects invalid machine LAN addresses and prefixes" do
    assert_raise ArgumentError, fn -> Network.machine_lan_config("not-an-ip", 24) end
    assert_raise ArgumentError, fn -> Network.machine_lan_config({192, 168, 10, 2}, 33) end
  end

  test "resolves both Ethernet roles by hardware path from a disabled baseline" do
    interfaces = [
      %{ifname: "eth1", hw_path: "/devices/usb/internet", kind: :ethernet},
      %{ifname: "eth0", hw_path: "/devices/platform/plc", kind: :ethernet}
    ]

    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, settings} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_interface_hw_path" => "/devices/platform/plc",
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/usb/internet"
             })

    assert Network.ethernet_baseline(interfaces) == [
             {"eth1", Network.disabled_ethernet_config()},
             {"eth0", Network.disabled_ethernet_config()}
           ]

    assert {:ok, [{"eth0", machine}, {"eth1", internet}]} =
             Network.ethernet_configurations(settings, interfaces)

    assert machine.ipv4.method == :static
    refute Map.has_key?(machine.ipv4, :gateway)
    assert internet.ipv4.method == :dhcp
  end

  test "fails closed when an assigned Ethernet interface is not detected" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, settings} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_interface_hw_path" => "/devices/missing"
             })

    assert {:error, {:interface_not_found, :machine_lan, "/devices/missing"}} =
             Network.ethernet_configurations(settings, [])
  end

  test "reports only active Ethernet roles and the fixed service interfaces" do
    interfaces = [%{ifname: "eth0", hw_path: "/devices/internet", kind: :ethernet}]
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, settings} =
             Settings.update(settings, %{
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/internet"
             })

    assert Network.role_ifnames(settings, interfaces) == %{
             internet_uplink: "eth0",
             machine_lan: nil,
             recovery: "usb0",
             service_ap: "wlan0"
           }
  end

  test "builds an open first-boot commissioning AP" do
    service = %{address: "192.168.50.1", prefix_length: 24, psk: "commissioning-key"}
    config = Network.service_access_point_config(service, "PLC-Remote-SETUP", "DE", :open)
    [access_point] = config.vintage_net_wifi.networks

    assert access_point == %{mode: :ap, ssid: "PLC-Remote-SETUP", key_mgmt: :none}
  end

  test "builds a WPA2 recovery AP with captive DNS and DHCP" do
    service = %{address: "192.168.50.1", prefix_length: 24, psk: "commissioning-key"}
    config = Network.service_access_point_config(service, "PLC-Remote-1234", "DE")
    [access_point] = config.vintage_net_wifi.networks

    assert access_point.mode == :ap
    assert access_point.key_mgmt == :wpa_psk
    assert access_point.proto == "RSN"
    assert config.ipv4.address == "192.168.50.1"
    assert config.dhcpd.options.dns == ["192.168.50.1"]
    assert {"*", "192.168.50.1"} in config.dnsd.records
  end
end
