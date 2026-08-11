defmodule PlcRemote.SettingsTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Settings

  test "defaults fail closed and include a unique service credential" do
    settings = Settings.defaults(gpio_spec: "PIN16", service_psk: "commissioning-key")

    refute settings.commissioned
    refute settings.machine.enabled
    refute settings.tailscale.enabled
    assert settings.uplink.mode == :disabled
    assert settings.machine.interface_hw_path == ""
    assert settings.uplink.ethernet.interface_hw_path == ""
    assert settings.service.gpio_spec == "PIN16"
    assert settings.service.active_level == 0
    assert settings.service.hold_ms == 3_000
    assert settings.service.timeout_ms == 900_000
    assert settings.service.psk == "commissioning-key"
  end

  test "updates and validates all remote access fields" do
    current = Settings.defaults(service_psk: "commissioning-key")

    params = %{
      "machine_enabled" => "true",
      "machine_interface_hw_path" => "/devices/platform/native-gigabit",
      "machine_address" => "10.20.30.1",
      "machine_prefix_length" => "24",
      "plc_address" => "10.20.30.10",
      "uplink_mode" => "ethernet",
      "regulatory_domain" => "de",
      "ethernet_interface_hw_path" => "/devices/platform/usb-2.5-gigabit",
      "ethernet_method" => "static",
      "ethernet_address" => "172.16.1.2",
      "ethernet_prefix_length" => "24",
      "ethernet_gateway" => "172.16.1.1",
      "ethernet_name_server" => "9.9.9.9",
      "tailscale_enabled" => "true",
      "tailscale_hostname" => "plant-remote-1",
      "tailscale_tags" => "tag:plc-gateway, tag:plant-1",
      "tailscale_auth_key" => "tskey-auth-once",
      "tailscale_listen_port" => "102",
      "plc_destination_port" => "102",
      "service_gpio_spec" => "PIN16",
      "service_active_level" => "0",
      "service_hold_seconds" => "4",
      "service_timeout_minutes" => "20",
      "service_ssid_prefix" => "PLC-Service",
      "service_psk" => "new-service-password"
    }

    assert {:ok, updated, "tskey-auth-once"} = Settings.update(current, params)
    assert updated.machine.plc_address == "10.20.30.10"
    assert updated.machine.interface_hw_path == "/devices/platform/native-gigabit"
    assert updated.uplink.mode == :ethernet

    assert updated.uplink.ethernet.interface_hw_path ==
             "/devices/platform/usb-2.5-gigabit"

    assert updated.uplink.ethernet.method == :static
    assert updated.uplink.regulatory_domain == "DE"
    assert updated.tailscale.hostname == "plant-remote-1"
    assert updated.tailscale.tags == ["tag:plc-gateway", "tag:plant-1"]
    assert updated.service.hold_ms == 4_000
    assert updated.service.timeout_ms == 1_200_000
  end

  test "commissioned state cannot be forged through portal parameters" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, updated, nil} = Settings.update(settings, %{"commissioned" => "true"})
    refute updated.commissioned
  end

  test "supports Ethernet-primary Wi-Fi fallback configuration" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, updated, nil} =
             Settings.update(settings, %{
               "uplink_mode" => "auto",
               "ethernet_interface_hw_path" => "/devices/usb/uplink",
               "wifi_ssid" => "Plant-WAN",
               "wifi_psk" => "fallback-secret"
             })

    assert updated.uplink.mode == :auto
    assert updated.uplink.ethernet.method == :dhcp
    assert updated.uplink.wifi.ssid == "Plant-WAN"
    assert updated.uplink.wifi.psk == "fallback-secret"
  end

  test "auth keys are never encoded into persistent settings" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:ok, updated, "tskey-auth-secret"} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_interface_hw_path" => "/devices/platform/machine",
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => "/devices/usb/uplink",
               "tailscale_auth_key" => "tskey-auth-secret"
             })

    assert updated.tailscale.enabled

    assert {:ok, encoded} = Settings.encode(updated)
    refute encoded =~ "tskey-auth-secret"
  end

  test "round trips persistent settings" do
    settings = Settings.defaults(gpio_spec: "PIN16", service_psk: "commissioning-key")
    assert {:ok, encoded} = Settings.encode(settings)
    assert {:ok, decoded} = Settings.decode(encoded, service_psk: "unused-fallback")
    assert decoded == settings
  end

  test "migrates legacy settings by disabling unassigned network roles" do
    legacy =
      Settings.defaults(service_psk: "commissioning-key")
      |> put_in([:version], 1)
      |> put_in([:machine, :enabled], true)
      |> put_in([:machine, :interface_hw_path], nil)
      |> put_in([:uplink, :mode], :auto)
      |> put_in([:uplink, :ethernet, :interface_hw_path], nil)
      |> put_in([:tailscale, :enabled], true)
      |> Jason.encode!()

    assert {:ok, migrated} = Settings.decode(legacy, service_psk: "unused")
    assert migrated.version == 3
    refute migrated.machine.enabled
    assert migrated.uplink.mode == :disabled
    refute migrated.tailscale.enabled
  end

  test "persists a completed commissioning marker" do
    settings =
      Settings.defaults(service_psk: "commissioning-key")
      |> Map.put(:commissioned, true)

    assert {:ok, encoded} = Settings.encode(settings)
    assert {:ok, decoded} = Settings.decode(encoded, service_psk: "unused")
    assert decoded.commissioned
  end

  test "additive schema upgrades preserve commissioned network settings" do
    version_two =
      Settings.defaults(service_psk: "commissioning-key")
      |> Map.put(:version, 2)
      |> Map.put(:commissioned, true)
      |> put_in([:machine, :enabled], true)
      |> put_in([:machine, :interface_hw_path], "/devices/platform/machine")
      |> put_in([:uplink, :mode], :ethernet)
      |> put_in([:uplink, :ethernet, :interface_hw_path], "/devices/usb/uplink")
      |> put_in([:tailscale, :enabled], true)
      |> Map.delete(:recovery)
      |> Jason.encode!()

    assert {:ok, migrated} = Settings.decode(version_two, service_psk: "unused")
    assert migrated.version == 3
    assert migrated.commissioned
    assert migrated.machine.enabled
    assert migrated.uplink.mode == :ethernet
    assert migrated.tailscale.enabled
    assert migrated.recovery.auto_reboot
  end

  test "validates bounded automatic recovery settings" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:error, errors} =
             Settings.update(settings, %{
               "recovery_reboot_after_minutes" => "5",
               "recovery_max_consecutive_reboots" => "9"
             })

    assert errors["recovery_reboot_after_minutes"] == "must be between 15 and 1440"
    assert errors["recovery_max_consecutive_reboots"] == "must be between 0 and 5"
  end

  test "requires active Ethernet roles to use different detected hardware paths" do
    settings = Settings.defaults(service_psk: "commissioning-key")
    path = "/devices/platform/shared-port"

    assert {:error, errors} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_interface_hw_path" => path,
               "uplink_mode" => "ethernet",
               "ethernet_interface_hw_path" => path
             })

    assert errors["ethernet_interface_hw_path"] == "must use a different physical port"
  end

  test "rejects invalid Tailscale tags" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:error, errors} =
             Settings.update(settings, %{"tailscale_tags" => "plc-gateway"})

    assert errors["tailscale_tags"] == "must be comma-separated tag:name values"
  end

  test "rejects PLC addresses outside the machine subnet" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:error, errors} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_address" => "192.168.10.1",
               "machine_prefix_length" => "24",
               "plc_address" => "192.168.20.10"
             })

    assert errors["plc_address"] == "must be inside the machine LAN subnet"
  end

  test "rejects overlap with the captive-portal network" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:error, errors} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_address" => "192.168.50.20",
               "machine_prefix_length" => "24",
               "plc_address" => "192.168.50.30"
             })

    assert errors["machine_address"] == "subnet overlaps the service-mode network"
  end

  test "rejects static uplinks that overlap the machine LAN" do
    settings = Settings.defaults(service_psk: "commissioning-key")

    assert {:error, errors} =
             Settings.update(settings, %{
               "machine_enabled" => "true",
               "machine_address" => "192.168.10.1",
               "machine_prefix_length" => "24",
               "plc_address" => "192.168.10.20",
               "ethernet_method" => "static",
               "ethernet_address" => "192.168.10.200",
               "ethernet_prefix_length" => "24",
               "ethernet_gateway" => "192.168.10.254",
               "ethernet_name_server" => "1.1.1.1"
             })

    assert errors["ethernet_address"] == "subnet overlaps the machine LAN"
  end

  test "detects IPv4 network overlap" do
    assert Settings.networks_overlap?("192.168.10.1", 24, "192.168.10.200", 25)
    refute Settings.networks_overlap?("192.168.10.1", 24, "192.168.11.1", 24)
  end
end
