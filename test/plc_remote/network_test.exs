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

  test "resolves Ethernet roles by hardware path and starts from a disabled baseline" do
    interfaces = [
      %{ifname: "eth1", hw_path: "/devices/usb/uplink", kind: :ethernet},
      %{ifname: "eth0", hw_path: "/devices/platform/machine", kind: :ethernet}
    ]

    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, settings, nil} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_interface_hw_path" => "/devices/platform/machine",
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/usb/uplink"
             })

    assert Network.ethernet_baseline(interfaces) == [
             {"eth1", Network.disabled_ethernet_config()},
             {"eth0", Network.disabled_ethernet_config()}
           ]

    assert {:ok, [{"eth0", machine}, {"eth1", uplink}]} =
             Network.ethernet_configurations(settings, interfaces)

    assert machine.ipv4.method == :static
    refute Map.has_key?(machine.ipv4, :gateway)
    assert uplink.ipv4.method == :dhcp
  end

  test "fails closed when an assigned Ethernet interface is not detected" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, settings, nil} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_interface_hw_path" => "/devices/missing"
             })

    assert {:error, {:interface_not_found, :machine_lan, "/devices/missing"}} =
             Network.ethernet_configurations(settings, [])
  end

  test "builds a Wi-Fi fallback uplink independently from wired Ethernet" do
    wifi = %{
      method: :dhcp,
      ssid: "Plant-WAN",
      psk: "fallback-secret"
    }

    config = Network.wifi_uplink_config(wifi, "DE")
    [network] = config.vintage_net_wifi.networks

    assert network.ssid == "Plant-WAN"
    assert network.key_mgmt == :wpa_psk
    assert config.ipv4.method == :dhcp
  end

  test "builds an open first-boot commissioning AP" do
    service = %{
      address: "192.168.50.1",
      prefix_length: 24,
      psk: "commissioning-key"
    }

    config = Network.service_access_point_config(service, "PLC-Remote-SETUP", "DE", :open)
    [access_point] = config.vintage_net_wifi.networks

    assert access_point == %{
             mode: :ap,
             ssid: "PLC-Remote-SETUP",
             key_mgmt: :none
           }
  end

  test "builds a WPA2 service AP with captive DNS and DHCP" do
    service = %{
      address: "192.168.50.1",
      prefix_length: 24,
      psk: "commissioning-key"
    }

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
