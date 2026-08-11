defmodule PlcRemote.Settings do
  @moduledoc """
  Validated, persistent configuration for networking, Tailscale, and service mode.

  Tailscale authentication keys are intentionally returned separately from the
  persistent settings so callers can consume them once without writing them to
  disk.
  """

  import Bitwise

  @version 3
  @default_service_address "192.168.50.1"

  @typedoc "Gateway settings with atom keys and normalized enum values."
  @type t :: %{
          version: pos_integer(),
          commissioned: boolean(),
          machine: map(),
          uplink: map(),
          tailscale: map(),
          service: map(),
          recovery: map()
        }

  @typedoc "Form validation errors keyed by field name."
  @type errors :: %{String.t() => String.t()}

  @doc "Builds secure defaults with the machine LAN, uplinks, and Tailscale disabled."
  @spec defaults(keyword()) :: t()
  def defaults(opts \\ []) do
    %{
      version: @version,
      commissioned: false,
      machine: %{
        enabled: false,
        interface_hw_path: "",
        address: "192.168.10.1",
        prefix_length: 24,
        plc_address: "192.168.10.2"
      },
      uplink: %{
        mode: :disabled,
        regulatory_domain: "00",
        ethernet: Map.put(default_ip_config(), :interface_hw_path, ""),
        wifi: Map.merge(default_ip_config(), %{ssid: "", psk: ""})
      },
      recovery: %{
        auto_reboot: true,
        reboot_after_ms: 3_600_000,
        max_consecutive_reboots: 2
      },
      tailscale: %{
        enabled: false,
        hostname: "plc-remote",
        tags: [],
        listen_port: 102,
        destination_port: 102
      },
      service: %{
        gpio_spec: Keyword.get(opts, :gpio_spec, default_gpio_spec()),
        active_level: 0,
        hold_ms: 3_000,
        timeout_ms: 900_000,
        ssid_prefix: "PLC-Remote",
        psk: Keyword.get_lazy(opts, :service_psk, &generate_service_psk/0),
        web_secret: Keyword.get_lazy(opts, :web_secret, &generate_web_secret/0),
        address: @default_service_address,
        prefix_length: 24
      }
    }
  end

  @doc "Encodes settings for storage."
  @spec encode(t()) :: {:ok, binary()} | {:error, Jason.EncodeError.t()}
  def encode(settings), do: Jason.encode(settings, pretty: true)

  @doc "Decodes and validates stored settings, filling fields added in newer versions."
  @spec decode(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode(json, opts \\ []) when is_binary(json) do
    with {:ok, value} <- Jason.decode(json),
         {:ok, settings, _auth_key} <- update(defaults(opts), storage_params(value)) do
      {:ok, Map.put(settings, :commissioned, stored_commissioned(value))}
    end
  end

  @doc """
  Applies web-form parameters and validates the complete configuration.

  A non-empty `tailscale_auth_key` is returned separately and is never inserted
  into the settings map.
  """
  @spec update(t(), map()) :: {:ok, t(), String.t() | nil} | {:error, errors()}
  def update(current, params) when is_map(params) do
    candidate = %{
      version: @version,
      commissioned: current.commissioned,
      machine: machine_settings(current.machine, params),
      uplink: uplink_settings(current.uplink, params),
      tailscale: tailscale_settings(current.tailscale, params),
      service: service_settings(current.service, params),
      recovery: recovery_settings(current.recovery, params)
    }

    case validate(candidate) do
      %{} = errors when map_size(errors) == 0 ->
        {:ok, candidate, blank_to_nil(param(params, "tailscale_auth_key", ""))}

      errors ->
        {:error, errors}
    end
  end

  @doc "Returns whether two IPv4 CIDR networks overlap."
  @spec networks_overlap?(String.t(), 0..32, String.t(), 0..32) :: boolean()
  def networks_overlap?(address_a, prefix_a, address_b, prefix_b) do
    with {:ok, integer_a} <- ip_to_integer(address_a),
         {:ok, integer_b} <- ip_to_integer(address_b),
         true <- valid_prefix?(prefix_a),
         true <- valid_prefix?(prefix_b) do
      shared_prefix = min(prefix_a, prefix_b)
      network(integer_a, shared_prefix) == network(integer_b, shared_prefix)
    else
      _ -> false
    end
  end

  defp machine_settings(current, params) do
    %{
      enabled: boolean_param(params, "machine_enabled", current.enabled),
      interface_hw_path: param(params, "machine_interface_hw_path", current.interface_hw_path),
      address: param(params, "machine_address", current.address),
      prefix_length: integer_param(params, "machine_prefix_length", current.prefix_length),
      plc_address: param(params, "plc_address", current.plc_address)
    }
  end

  defp uplink_settings(current, params) do
    %{
      mode: enum_param(params, "uplink_mode", current.mode, [:disabled, :auto, :ethernet, :wifi]),
      regulatory_domain:
        params
        |> param("regulatory_domain", current.regulatory_domain)
        |> String.upcase(),
      ethernet:
        current.ethernet
        |> ip_settings("ethernet", params)
        |> Map.put(
          :interface_hw_path,
          param(
            params,
            "ethernet_interface_hw_path",
            current.ethernet.interface_hw_path
          )
        ),
      wifi:
        current.wifi
        |> ip_settings("wifi", params)
        |> Map.merge(%{
          ssid: param(params, "wifi_ssid", current.wifi.ssid),
          psk: secret_param(params, "wifi_psk", current.wifi.psk)
        })
    }
  end

  defp ip_settings(current, prefix, params) do
    %{
      method: enum_param(params, "#{prefix}_method", current.method, [:dhcp, :static]),
      address: param(params, "#{prefix}_address", current.address),
      prefix_length: integer_param(params, "#{prefix}_prefix_length", current.prefix_length),
      gateway: param(params, "#{prefix}_gateway", current.gateway),
      name_server: param(params, "#{prefix}_name_server", current.name_server)
    }
  end

  defp tailscale_settings(current, params) do
    auth_key_supplied? = not is_nil(blank_to_nil(param(params, "tailscale_auth_key", "")))

    %{
      enabled: auth_key_supplied? or boolean_param(params, "tailscale_enabled", current.enabled),
      hostname: param(params, "tailscale_hostname", current.hostname),
      tags: tags_param(params, current.tags),
      listen_port: integer_param(params, "tailscale_listen_port", current.listen_port),
      destination_port: integer_param(params, "plc_destination_port", current.destination_port)
    }
  end

  defp recovery_settings(current, params) do
    %{
      auto_reboot: boolean_param(params, "recovery_auto_reboot", current.auto_reboot),
      reboot_after_ms:
        params
        |> integer_param("recovery_reboot_after_minutes", div(current.reboot_after_ms, 60_000))
        |> Kernel.*(60_000),
      max_consecutive_reboots:
        integer_param(
          params,
          "recovery_max_consecutive_reboots",
          current.max_consecutive_reboots
        )
    }
  end

  defp service_settings(current, params) do
    %{
      gpio_spec: param(params, "service_gpio_spec", current.gpio_spec),
      active_level: integer_param(params, "service_active_level", current.active_level),
      hold_ms:
        params
        |> integer_param("service_hold_seconds", div(current.hold_ms, 1_000))
        |> Kernel.*(1_000),
      timeout_ms:
        params
        |> integer_param("service_timeout_minutes", div(current.timeout_ms, 60_000))
        |> Kernel.*(60_000),
      ssid_prefix: param(params, "service_ssid_prefix", current.ssid_prefix),
      psk: secret_param(params, "service_psk", current.psk),
      web_secret: param(params, "service_web_secret", current.web_secret),
      address: current.address,
      prefix_length: current.prefix_length
    }
  end

  defp validate(settings) do
    %{}
    |> validate_machine(settings.machine)
    |> validate_uplink(settings.uplink)
    |> validate_interface_roles(settings)
    |> validate_tailscale(settings.tailscale, settings.machine, settings.uplink)
    |> validate_service(settings.service)
    |> validate_recovery(settings.recovery)
    |> validate_network_separation(settings)
  end

  defp validate_machine(errors, machine) do
    errors
    |> require_ip("machine_address", machine.address)
    |> require_prefix("machine_prefix_length", machine.prefix_length)
    |> require_ip("plc_address", machine.plc_address)
    |> validate_plc_subnet(machine)
  end

  defp validate_plc_subnet(errors, %{enabled: false}), do: errors

  defp validate_plc_subnet(errors, machine) do
    if same_subnet?(
         machine.address,
         machine.plc_address,
         machine.prefix_length
       ) do
      errors
    else
      Map.put(errors, "plc_address", "must be inside the machine LAN subnet")
    end
  end

  defp validate_uplink(errors, uplink) do
    errors
    |> validate_regulatory_domain(uplink.regulatory_domain)
    |> validate_ip_config("ethernet", uplink.ethernet)
    |> validate_ip_config("wifi", uplink.wifi)
    |> validate_wifi(uplink)
  end

  defp validate_regulatory_domain(errors, domain) do
    if domain == "00" or Regex.match?(~r/^[A-Z]{2}$/, domain) do
      errors
    else
      Map.put(errors, "regulatory_domain", "must be a two-letter country code")
    end
  end

  defp validate_ip_config(errors, _prefix, %{method: :dhcp}), do: errors

  defp validate_ip_config(errors, prefix, config) do
    errors
    |> require_ip("#{prefix}_address", config.address)
    |> require_prefix("#{prefix}_prefix_length", config.prefix_length)
    |> require_ip("#{prefix}_gateway", config.gateway)
    |> require_ip("#{prefix}_name_server", config.name_server)
  end

  defp validate_wifi(errors, %{mode: mode}) when mode in [:disabled, :ethernet], do: errors

  defp validate_wifi(errors, %{mode: :auto, wifi: %{ssid: ""}}), do: errors

  defp validate_wifi(errors, %{mode: :wifi, wifi: %{ssid: ""}}) do
    Map.put(errors, "wifi_ssid", "is required when Wi-Fi is the selected uplink")
  end

  defp validate_wifi(errors, %{wifi: %{psk: psk}}) when byte_size(psk) in 8..63, do: errors

  defp validate_wifi(errors, _uplink) do
    Map.put(errors, "wifi_psk", "must contain 8 to 63 characters")
  end

  defp validate_interface_roles(errors, settings) do
    machine_path = settings.machine.interface_hw_path
    wired_path = settings.uplink.ethernet.interface_hw_path
    wired_active? = settings.uplink.mode in [:auto, :ethernet]

    errors =
      errors
      |> validate_hw_path("machine_interface_hw_path", machine_path)
      |> validate_hw_path("ethernet_interface_hw_path", wired_path)
      |> require_assigned_path(
        "machine_interface_hw_path",
        machine_path,
        settings.machine.enabled
      )
      |> require_assigned_path("ethernet_interface_hw_path", wired_path, wired_active?)

    if settings.machine.enabled and wired_active? and machine_path not in [nil, ""] and
         machine_path == wired_path do
      Map.put(errors, "ethernet_interface_hw_path", "must use a different physical port")
    else
      errors
    end
  end

  defp validate_hw_path(errors, _field, ""), do: errors

  defp validate_hw_path(errors, field, path) do
    if is_binary(path) and byte_size(path) <= 512 and String.starts_with?(path, "/devices/") do
      errors
    else
      Map.put(errors, field, "is not a valid detected hardware path")
    end
  end

  defp require_assigned_path(errors, _field, path, true) when path not in [nil, ""], do: errors

  defp require_assigned_path(errors, field, _path, true),
    do: Map.put(errors, field, "is required")

  defp require_assigned_path(errors, _field, _path, false), do: errors

  defp validate_tailscale(errors, tailscale, machine, uplink) do
    errors =
      errors
      |> validate_hostname(tailscale.hostname)
      |> validate_tags(tailscale.tags)
      |> require_port("tailscale_listen_port", tailscale.listen_port)
      |> require_port("plc_destination_port", tailscale.destination_port)

    cond do
      tailscale.enabled and not machine.enabled ->
        Map.put(errors, "tailscale_enabled", "requires the machine LAN to be enabled")

      tailscale.enabled and uplink.mode == :disabled ->
        Map.put(errors, "tailscale_enabled", "requires an Internet uplink")

      true ->
        errors
    end
  end

  defp validate_hostname(errors, hostname) do
    if Regex.match?(~r/^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/, hostname) do
      errors
    else
      Map.put(errors, "tailscale_hostname", "is not a valid hostname")
    end
  end

  defp validate_tags(errors, tags) do
    if Enum.all?(tags, &Regex.match?(~r/^tag:[A-Za-z0-9-]+$/, &1)) do
      errors
    else
      Map.put(errors, "tailscale_tags", "must be comma-separated tag:name values")
    end
  end

  defp validate_service(errors, service) do
    errors
    |> require_non_empty("service_gpio_spec", service.gpio_spec)
    |> require_enum("service_active_level", service.active_level, [0, 1])
    |> require_range("service_hold_seconds", div(service.hold_ms, 1_000), 0..30)
    |> require_range("service_timeout_minutes", div(service.timeout_ms, 60_000), 1..120)
    |> require_ssid_prefix(service.ssid_prefix)
    |> require_psk("service_psk", service.psk)
    |> require_web_secret(service.web_secret)
    |> require_ip("service_address", service.address)
    |> require_prefix("service_prefix_length", service.prefix_length)
  end

  defp validate_recovery(errors, recovery) do
    errors
    |> require_range(
      "recovery_reboot_after_minutes",
      div(recovery.reboot_after_ms, 60_000),
      15..1_440
    )
    |> require_range(
      "recovery_max_consecutive_reboots",
      recovery.max_consecutive_reboots,
      0..5
    )
  end

  defp validate_network_separation(errors, settings) do
    uplink_networks =
      []
      |> add_static_uplink("ethernet_address", settings.uplink.ethernet)
      |> add_static_uplink("wifi_address", settings.uplink.wifi)

    configured_networks = [
      {"machine_address", settings.machine.enabled, settings.machine} | uplink_networks
    ]

    errors =
      validate_no_overlap(
        errors,
        configured_networks,
        settings.service,
        "service-mode network"
      )

    if settings.machine.enabled do
      validate_no_overlap(errors, uplink_networks, settings.machine, "machine LAN")
    else
      errors
    end
  end

  defp validate_no_overlap(errors, networks, reference, reference_name) do
    Enum.reduce(networks, errors, fn
      {_field, false, _config}, acc ->
        acc

      {field, true, config}, acc ->
        if networks_overlap?(
             config.address,
             config.prefix_length,
             reference.address,
             reference.prefix_length
           ) do
          Map.put(acc, field, "subnet overlaps the #{reference_name}")
        else
          acc
        end
    end)
  end

  defp add_static_uplink(networks, field, %{method: :static} = config),
    do: [{field, true, config} | networks]

  defp add_static_uplink(networks, _field, _config), do: networks

  defp require_ip(errors, field, value) do
    case ip_to_integer(value) do
      {:ok, _integer} -> errors
      :error -> Map.put(errors, field, "must be a valid IPv4 address")
    end
  end

  defp require_prefix(errors, field, value),
    do: require_range(errors, field, value, 1..30)

  defp require_port(errors, field, value),
    do: require_range(errors, field, value, 1..65_535)

  defp require_psk(errors, _field, value) when byte_size(value) in 8..63, do: errors

  defp require_psk(errors, field, _value),
    do: Map.put(errors, field, "must contain 8 to 63 characters")

  defp require_ssid_prefix(errors, value) do
    if Regex.match?(~r/^[A-Za-z0-9 _-]{1,20}$/, value) do
      errors
    else
      Map.put(
        errors,
        "service_ssid_prefix",
        "must be 1 to 20 ASCII letters, digits, spaces, _ or -"
      )
    end
  end

  defp require_web_secret(errors, secret) when is_binary(secret) and byte_size(secret) >= 32,
    do: errors

  defp require_web_secret(errors, _secret),
    do: Map.put(errors, "service_web_secret", "is invalid")

  defp require_non_empty(errors, _field, value) when is_binary(value) and value != "",
    do: errors

  defp require_non_empty(errors, field, _value), do: Map.put(errors, field, "is required")

  defp require_enum(errors, field, value, allowed) do
    if value in allowed, do: errors, else: Map.put(errors, field, "is invalid")
  end

  defp require_range(errors, field, value, range) do
    if is_integer(value) and value in range do
      errors
    else
      Map.put(errors, field, "must be between #{range.first} and #{range.last}")
    end
  end

  defp same_subnet?(address_a, address_b, prefix) do
    with {:ok, integer_a} <- ip_to_integer(address_a),
         {:ok, integer_b} <- ip_to_integer(address_b),
         true <- valid_prefix?(prefix) do
      network(integer_a, prefix) == network(integer_b, prefix)
    else
      _ -> false
    end
  end

  defp ip_to_integer(address) when is_binary(address) do
    case :inet.parse_ipv4_address(String.to_charlist(address)) do
      {:ok, {a, b, c, d}} -> {:ok, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}
      {:error, :einval} -> :error
    end
  end

  defp ip_to_integer(_address), do: :error

  defp valid_prefix?(prefix), do: is_integer(prefix) and prefix in 0..32

  defp network(_address, 0), do: 0

  defp network(address, prefix) do
    mask = 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF
    address &&& mask
  end

  defp default_ip_config do
    %{
      method: :dhcp,
      address: "192.168.1.2",
      prefix_length: 24,
      gateway: "192.168.1.1",
      name_server: "1.1.1.1"
    }
  end

  defp default_gpio_spec do
    Application.get_env(:plc_remote, :default_service_gpio, "GPIO17")
  end

  defp generate_service_psk do
    10
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end

  defp generate_web_secret do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp storage_params(value) do
    machine = Map.get(value, "machine", %{})
    uplink = Map.get(value, "uplink", %{})
    ethernet = Map.get(uplink, "ethernet", %{})
    wifi = Map.get(uplink, "wifi", %{})
    tailscale = Map.get(value, "tailscale", %{})
    service = Map.get(value, "service", %{})
    recovery = Map.get(value, "recovery", %{})

    params = %{
      "machine_enabled" => Map.get(machine, "enabled"),
      "machine_interface_hw_path" => Map.get(machine, "interface_hw_path"),
      "machine_address" => Map.get(machine, "address"),
      "machine_prefix_length" => Map.get(machine, "prefix_length"),
      "plc_address" => Map.get(machine, "plc_address"),
      "uplink_mode" => Map.get(uplink, "mode"),
      "regulatory_domain" => Map.get(uplink, "regulatory_domain"),
      "ethernet_interface_hw_path" => Map.get(ethernet, "interface_hw_path"),
      "ethernet_method" => Map.get(ethernet, "method"),
      "ethernet_address" => Map.get(ethernet, "address"),
      "ethernet_prefix_length" => Map.get(ethernet, "prefix_length"),
      "ethernet_gateway" => Map.get(ethernet, "gateway"),
      "ethernet_name_server" => Map.get(ethernet, "name_server"),
      "wifi_ssid" => Map.get(wifi, "ssid"),
      "wifi_psk" => Map.get(wifi, "psk"),
      "wifi_method" => Map.get(wifi, "method"),
      "wifi_address" => Map.get(wifi, "address"),
      "wifi_prefix_length" => Map.get(wifi, "prefix_length"),
      "wifi_gateway" => Map.get(wifi, "gateway"),
      "wifi_name_server" => Map.get(wifi, "name_server"),
      "tailscale_enabled" => Map.get(tailscale, "enabled"),
      "tailscale_hostname" => Map.get(tailscale, "hostname"),
      "tailscale_tags" => join_tags(Map.get(tailscale, "tags")),
      "tailscale_listen_port" => Map.get(tailscale, "listen_port"),
      "plc_destination_port" => Map.get(tailscale, "destination_port"),
      "recovery_auto_reboot" => Map.get(recovery, "auto_reboot"),
      "recovery_reboot_after_minutes" => divide(Map.get(recovery, "reboot_after_ms"), 60_000),
      "recovery_max_consecutive_reboots" => Map.get(recovery, "max_consecutive_reboots"),
      "service_gpio_spec" => Map.get(service, "gpio_spec"),
      "service_active_level" => Map.get(service, "active_level"),
      "service_hold_seconds" => divide(Map.get(service, "hold_ms"), 1_000),
      "service_timeout_minutes" => divide(Map.get(service, "timeout_ms"), 60_000),
      "service_ssid_prefix" => Map.get(service, "ssid_prefix"),
      "service_psk" => Map.get(service, "psk"),
      "service_web_secret" => Map.get(service, "web_secret")
    }

    params = Map.reject(params, fn {_key, stored_value} -> is_nil(stored_value) end)

    if stored_version(value) < 2 do
      params
      |> Map.put("machine_enabled", false)
      |> Map.put("uplink_mode", "disabled")
      |> Map.put("tailscale_enabled", false)
    else
      params
    end
  end

  defp stored_commissioned(value) do
    stored_version(value) >= 2 and Map.get(value, "commissioned") == true
  end

  defp stored_version(value) do
    case Map.get(value, "version", 1) do
      version when is_integer(version) -> version
      _other -> 1
    end
  end

  defp divide(value, divisor) when is_integer(value), do: div(value, divisor)
  defp divide(_value, _divisor), do: nil

  defp join_tags(tags) when is_list(tags), do: Enum.join(tags, ",")
  defp join_tags(_tags), do: ""

  defp tags_param(params, current) do
    params
    |> param("tailscale_tags", Enum.join(current, ","))
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp param(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      value when is_binary(value) -> String.trim(value)
      value -> value
    end
  end

  defp secret_param(params, key, current) do
    case param(params, key, current) do
      "" -> current
      value -> value
    end
  end

  defp boolean_param(params, key, default) do
    case Map.get(params, key, default) do
      value when value in [true, 1, "1", "true", "on"] -> true
      _other -> false
    end
  end

  defp integer_param(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _other -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> default
    end
  end

  defp enum_param(params, key, default, allowed) do
    value = param(params, key, Atom.to_string(default))

    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
