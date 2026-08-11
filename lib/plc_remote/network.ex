defmodule PlcRemote.Network do
  @moduledoc """
  Network roles and commissioning helpers for the PLC access gateway.

  The machine LAN is fail-closed: it must be assigned a static address and the
  generated configuration never includes a default gateway or DNS servers.
  Internet traffic therefore uses the wired uplink or provisioned Wi-Fi.
  """

  @wifi_uplink_interface "wlan0"
  @recovery_interface "usb0"

  @typedoc "A physical or recovery network role."
  @type role :: :machine_lan | :wired_uplink | :wifi_uplink | :recovery

  @typedoc "A Linux network interface name."
  @type ifname :: String.t()

  @typedoc "A detected network interface."
  @type interface_info :: PlcRemote.Adapters.Network.interface_info()

  @doc "Returns the fixed interface name assigned to a non-Ethernet role."
  @spec interface(:wifi_uplink | :recovery) :: ifname()
  def interface(:wifi_uplink), do: @wifi_uplink_interface
  def interface(:recovery), do: @recovery_interface

  @doc "Returns fail-closed configurations for every detected Ethernet interface."
  @spec ethernet_baseline([interface_info()]) :: [{ifname(), map()}]
  def ethernet_baseline(interfaces) do
    for %{ifname: ifname, kind: :ethernet} <- interfaces do
      {ifname, disabled_ethernet_config()}
    end
  end

  @doc "Resolves hardware-path role assignments and builds active Ethernet configurations."
  @spec ethernet_configurations(map(), [interface_info()]) ::
          {:ok, [{ifname(), map()}]} | {:error, term()}
  def ethernet_configurations(settings, interfaces) do
    machine_active? = settings.machine.enabled
    wired_active? = settings.uplink.mode in [:auto, :ethernet]

    with {:ok, machine_ifname} <-
           resolve_interface(
             interfaces,
             settings.machine.interface_hw_path,
             :machine_lan,
             machine_active?
           ),
         {:ok, wired_ifname} <-
           resolve_interface(
             interfaces,
             settings.uplink.ethernet.interface_hw_path,
             :wired_uplink,
             wired_active?
           ),
         :ok <-
           distinct_active_interfaces(
             machine_ifname,
             wired_ifname,
             machine_active?,
             wired_active?
           ) do
      configurations =
        []
        |> maybe_add_machine(machine_ifname, settings.machine, machine_active?)
        |> maybe_add_wired(wired_ifname, settings.uplink.ethernet, wired_active?)
        |> Enum.reverse()

      {:ok, configurations}
    end
  end

  @doc "Returns current interface names for configured hardware-path roles."
  @spec role_ifnames(map(), [interface_info()]) :: %{role() => ifname() | nil}
  def role_ifnames(settings, interfaces) do
    %{
      machine_lan: find_ifname(interfaces, settings.machine.interface_hw_path),
      recovery: @recovery_interface,
      wifi_uplink: @wifi_uplink_interface,
      wired_uplink: find_ifname(interfaces, settings.uplink.ethernet.interface_hw_path)
    }
  end

  @doc """
  Builds a static, non-routing configuration for the machine LAN.

  `address` may be an IPv4 tuple or string. No gateway or name server can be
  supplied through this API.
  """
  @spec machine_lan_config(:inet.ip4_address() | String.t(), 0..32) :: map()
  def machine_lan_config(address, prefix_length \\ 24)

  def machine_lan_config(address, prefix_length) when is_binary(address) do
    case :inet.parse_ipv4_address(String.to_charlist(address)) do
      {:ok, parsed_address} -> machine_lan_config(parsed_address, prefix_length)
      {:error, :einval} -> raise ArgumentError, "invalid IPv4 address: #{inspect(address)}"
    end
  end

  def machine_lan_config({a, b, c, d} = address, prefix_length)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 and
             prefix_length in 0..32 do
    %{
      type: VintageNetEthernet,
      ipv4: %{
        method: :static,
        address: address,
        prefix_length: prefix_length
      }
    }
  end

  def machine_lan_config(address, prefix_length) do
    raise ArgumentError,
          "invalid machine LAN address/prefix: #{inspect(address)}/#{inspect(prefix_length)}"
  end

  @doc "Builds a disabled configuration for a wired interface."
  @spec disabled_ethernet_config() :: map()
  def disabled_ethernet_config do
    %{type: VintageNetEthernet, ipv4: %{method: :disabled}}
  end

  @doc "Builds a DHCP or static wired-uplink configuration."
  @spec wired_uplink_config(map()) :: map()
  def wired_uplink_config(ip_config) do
    %{type: VintageNetEthernet, ipv4: ipv4_config(ip_config)}
  end

  @doc "Builds a station-mode Wi-Fi uplink configuration."
  @spec wifi_uplink_config(map(), String.t()) :: map()
  def wifi_uplink_config(%{ssid: ""}, _regulatory_domain),
    do: %{type: VintageNetWiFi}

  def wifi_uplink_config(wifi, regulatory_domain) do
    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        regulatory_domain: regulatory_domain,
        networks: [
          %{
            ssid: wifi.ssid,
            psk: wifi.psk,
            key_mgmt: :wpa_psk
          }
        ]
      },
      ipv4: ipv4_config(wifi)
    }
  end

  @doc "Builds the isolated service access point and captive DNS configuration."
  @spec service_access_point_config(map(), String.t(), String.t(), :open | :wpa2) :: map()
  def service_access_point_config(service, ssid, regulatory_domain, security \\ :wpa2) do
    address = service.address
    {a, b, c, _d} = parse_ipv4!(address)

    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        regulatory_domain: regulatory_domain,
        networks: [access_point_network(service, ssid, security)]
      },
      ipv4: %{
        method: :static,
        address: address,
        prefix_length: service.prefix_length
      },
      dhcpd: %{
        start: {a, b, c, 20},
        end: {a, b, c, 250},
        max_leases: 231,
        options: %{
          dns: [address],
          router: [address],
          subnet: {255, 255, 255, 0},
          domain: "plc.setup",
          search: ["plc.setup"]
        }
      },
      dnsd: %{
        records: [{"plc.setup", address}, {"*", address}]
      }
    }
  end

  defp access_point_network(_service, ssid, :open) do
    %{mode: :ap, ssid: ssid, key_mgmt: :none}
  end

  defp access_point_network(service, ssid, :wpa2) do
    %{
      mode: :ap,
      ssid: ssid,
      psk: service.psk,
      key_mgmt: :wpa_psk,
      proto: "RSN",
      pairwise: "CCMP",
      group: "CCMP"
    }
  end

  defp resolve_interface(interfaces, hw_path, role, required?) do
    case find_ifname(interfaces, hw_path) do
      nil when required? and hw_path in [nil, ""] -> {:error, {:interface_unassigned, role}}
      nil when required? -> {:error, {:interface_not_found, role, hw_path}}
      ifname -> {:ok, ifname}
    end
  end

  defp distinct_active_interfaces(ifname, ifname, true, true),
    do: {:error, {:duplicate_interface_assignment, ifname}}

  defp distinct_active_interfaces(_machine, _wired, _machine_active, _wired_active), do: :ok

  defp maybe_add_machine(configurations, ifname, machine, true) do
    [{ifname, machine_lan_config(machine.address, machine.prefix_length)} | configurations]
  end

  defp maybe_add_machine(configurations, _ifname, _machine, false), do: configurations

  defp maybe_add_wired(configurations, ifname, ethernet, true) do
    [{ifname, wired_uplink_config(ethernet)} | configurations]
  end

  defp maybe_add_wired(configurations, _ifname, _ethernet, false), do: configurations

  defp find_ifname(_interfaces, hw_path) when hw_path in [nil, ""], do: nil

  defp find_ifname(interfaces, hw_path) do
    case Enum.find(interfaces, &(&1.kind == :ethernet and &1.hw_path == hw_path)) do
      nil -> nil
      interface -> interface.ifname
    end
  end

  defp ipv4_config(%{method: :dhcp}), do: %{method: :dhcp}

  defp ipv4_config(%{method: :static} = config) do
    %{
      method: :static,
      address: config.address,
      prefix_length: config.prefix_length,
      gateway: config.gateway,
      name_servers: [config.name_server]
    }
  end

  defp parse_ipv4!(address) do
    case :inet.parse_ipv4_address(String.to_charlist(address)) do
      {:ok, parsed} -> parsed
      {:error, :einval} -> raise ArgumentError, "invalid IPv4 address: #{inspect(address)}"
    end
  end
end
