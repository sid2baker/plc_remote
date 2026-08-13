defmodule PlcRemote.Network do
  @moduledoc """
  Public API and pure configuration helpers for the two Ethernet roles.

  Runtime operations delegate to `Network.Runtime`; plan construction remains
  pure so disable-first and isolation invariants can be tested exhaustively.
  """

  @service_interface "wlan0"
  @recovery_interface "usb0"

  @typedoc "A physical or recovery network role."
  @type role :: :machine_lan | :internet_uplink | :service_ap | :recovery
  @typedoc "A Linux network interface name."
  @type ifname :: String.t()
  @typedoc "A detected network interface."
  @type interface_info :: PlcRemote.Adapters.Network.interface_info()

  @spec status() :: PlcRemote.Network.Status.t()
  defdelegate status(), to: PlcRemote.Network.Runtime

  @spec reapply() :: :ok | {:error, term()}
  defdelegate reapply(), to: PlcRemote.Network.Runtime

  @spec cycle_uplink() :: :ok | {:error, term()}
  defdelegate cycle_uplink(), to: PlcRemote.Network.Runtime

  @doc "Returns the fixed interface name assigned to a non-Ethernet role."
  @spec interface(:service_ap | :recovery) :: ifname()
  def interface(:service_ap), do: @service_interface
  def interface(:recovery), do: @recovery_interface

  @doc "Returns fail-closed configurations for every detected Ethernet interface."
  @spec ethernet_baseline([interface_info()]) :: [{ifname(), map()}]
  def ethernet_baseline(interfaces) do
    for %{ifname: ifname, kind: :ethernet} <- interfaces do
      {ifname, disabled_ethernet_config()}
    end
  end

  @doc "Resolves stable hardware paths and builds active Ethernet configurations."
  @spec ethernet_configurations(map(), [interface_info()]) ::
          {:ok, [{ifname(), map()}]} | {:error, term()}
  def ethernet_configurations(settings, interfaces) do
    machine_active? = settings.machine.enabled
    internet_active? = settings.uplink.mode == :ethernet

    with {:ok, machine_ifname} <-
           resolve_interface(
             interfaces,
             settings.machine.interface_hw_path,
             :machine_lan,
             machine_active?
           ),
         {:ok, internet_ifname} <-
           resolve_interface(
             interfaces,
             settings.uplink.ethernet.interface_hw_path,
             :internet_uplink,
             internet_active?
           ),
         :ok <-
           distinct_active_interfaces(
             machine_ifname,
             internet_ifname,
             machine_active?,
             internet_active?
           ) do
      configurations =
        []
        |> maybe_add_machine(machine_ifname, settings.machine, machine_active?)
        |> maybe_add_internet(internet_ifname, settings.uplink.ethernet, internet_active?)
        |> Enum.reverse()

      {:ok, configurations}
    end
  end

  @doc "Returns current interface names for configured and active roles."
  @spec role_ifnames(map(), [interface_info()]) :: %{role() => ifname() | nil}
  def role_ifnames(settings, interfaces) do
    %{
      machine_lan:
        active_ifname(interfaces, settings.machine.interface_hw_path, settings.machine.enabled),
      internet_uplink:
        active_ifname(
          interfaces,
          settings.uplink.ethernet.interface_hw_path,
          settings.uplink.mode == :ethernet
        ),
      service_ap: @service_interface,
      recovery: @recovery_interface
    }
  end

  @doc "Builds a static, non-routing configuration for the PLC LAN."
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
      ipv4: %{method: :static, address: address, prefix_length: prefix_length}
    }
  end

  def machine_lan_config(address, prefix_length) do
    raise ArgumentError,
          "invalid machine LAN address/prefix: #{inspect(address)}/#{inspect(prefix_length)}"
  end

  @doc "Builds a disabled configuration for a wired interface."
  @spec disabled_ethernet_config() :: map()
  def disabled_ethernet_config, do: %{type: VintageNetEthernet, ipv4: %{method: :disabled}}

  @doc "Builds a DHCP or static Internet Ethernet configuration."
  @spec internet_uplink_config(map()) :: map()
  def internet_uplink_config(ip_config),
    do: %{type: VintageNetEthernet, ipv4: ipv4_config(ip_config)}

  @doc "Builds the WPA2 service-router access point and DHCP configuration."
  @spec service_access_point_config(map(), String.t(), String.t()) :: map()
  def service_access_point_config(service, ssid, regulatory_domain) do
    address = service.address
    {a, b, c, _d} = parse_ipv4!(address)

    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        regulatory_domain: regulatory_domain,
        networks: [access_point_network(service, ssid)]
      },
      ipv4: %{method: :static, address: address, prefix_length: service.prefix_length},
      dhcpd: %{
        start: {a, b, c, 20},
        end: {a, b, c, 250},
        max_leases: 231,
        options: %{
          dns: [{1, 1, 1, 1}, {8, 8, 8, 8}],
          router: [address],
          subnet: {255, 255, 255, 0},
          domain: "plc.setup",
          search: ["plc.setup"]
        }
      }
    }
  end

  defp access_point_network(service, ssid) do
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

  defp distinct_active_interfaces(_machine, _internet, _machine_active, _internet_active), do: :ok

  defp maybe_add_machine(configurations, ifname, machine, true) do
    [{ifname, machine_lan_config(machine.address, machine.prefix_length)} | configurations]
  end

  defp maybe_add_machine(configurations, _ifname, _machine, false), do: configurations

  defp maybe_add_internet(configurations, ifname, ethernet, true) do
    [{ifname, internet_uplink_config(ethernet)} | configurations]
  end

  defp maybe_add_internet(configurations, _ifname, _ethernet, false), do: configurations
  defp active_ifname(interfaces, path, true), do: find_ifname(interfaces, path)
  defp active_ifname(_interfaces, _path, false), do: nil
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
