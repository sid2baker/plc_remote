defmodule PlcRemote.Integration do
  @moduledoc false

  @wan_mac "02:00:00:00:00:10"
  @plc_mac "02:00:00:00:00:20"
  @plc_address "192.168.10.100"
  @plc_port 10_102
  @nif_smoke_path "/data/plc_remote/integration/nif-smoke.json"
  @tailnet_identity_path "/data/plc_remote/integration/tailnet-identity.json"

  @spec health() :: map()
  def health do
    %{
      application: application_running?(:plc_remote),
      alarms: PlcRemote.Health.active_alarms(),
      network: PlcRemote.Network.status(),
      panel: PlcRemote.Panel.status(),
      service: PlcRemote.Service.status(),
      supervision: supervision(),
      tailscale: PlcRemote.Tailscale.status()
    }
  end

  @spec interfaces() :: [map()]
  def interfaces do
    PlcRemote.Network.status().interfaces
  end

  @spec enroll_invalid_tailnet() :: {:ok, map()} | {:error, term()}
  def enroll_invalid_tailnet do
    settings = PlcRemote.Configuration.current()

    with {:ok, candidate} <-
           PlcRemote.Settings.update(settings, %{
             "tailscale_enabled" => "true",
             "tailscale_hostname" => "plc-remote-invalid-ci"
           }),
         {:ok, enrollment} <-
           PlcRemote.Tailscale.Enrollment.new("tskey-auth-invalid-plc-remote-ci"),
         {:error, reason} <- PlcRemote.Tailscale.enroll(enrollment, candidate) do
      {:ok,
       %{
         failed_closed: not PlcRemote.Configuration.current().tailscale.enabled,
         reason: reason
       }}
    end
  end

  @spec provision_ethernet_roles(:inet.port_number()) :: {:ok, map()} | {:error, term()}
  def provision_ethernet_roles(destination_port \\ 102) do
    with {:ok, wan} <- interface_by_mac(@wan_mac),
         {:ok, plc} <- interface_by_mac(@plc_mac),
         {:ok, settings} <-
           PlcRemote.Configuration.update(%{
             "uplink_mode" => "ethernet",
             "ethernet_method" => "dhcp",
             "ethernet_interface_hw_path" => wan.hw_path,
             "machine_enabled" => "true",
             "machine_interface_hw_path" => plc.hw_path,
             "machine_address" => "192.168.10.1",
             "machine_prefix_length" => "24",
             "plc_address" => @plc_address,
             "plc_destination_port" => Integer.to_string(destination_port),
             "recovery_auto_reboot" => "false"
           }),
         :ok <- PlcRemote.Network.reapply() do
      {:ok,
       %{
         settings: redacted_settings(settings),
         status: PlcRemote.Network.status()
       }}
    end
  end

  @spec await_connection(atom(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def await_connection(expected, timeout_ms \\ 30_000) do
    await(
      fn ->
        status = PlcRemote.Network.status()
        if status.connection == expected, do: {:ok, status}, else: :retry
      end,
      timeout_ms
    )
  end

  @spec await_interface_link(String.t(), boolean(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def await_interface_link(mac, expected, timeout_ms \\ 30_000) do
    await(
      fn ->
        with {:ok, interface} <- interface_by_mac(mac),
             true <- interface.lower_up == expected do
          {:ok, Map.take(interface, [:hw_path, :ifname, :lower_up, :mac_address])}
        else
          _other -> :retry
        end
      end,
      timeout_ms
    )
  end

  @spec enroll_tailnet(Path.t()) :: {:ok, map()} | {:error, term()}
  def enroll_tailnet(payload_path) do
    with :ok <- File.chmod(payload_path, 0o600),
         {:ok, encoded} <- File.read(payload_path),
         :ok <- File.rm(payload_path),
         {:ok, enrollment} <- decode_enrollment(encoded),
         {:ok, candidate} <-
           PlcRemote.Settings.update(PlcRemote.Configuration.current(), %{
             "tailscale_enabled" => "true",
             "tailscale_hostname" => enrollment.hostname,
             "tailscale_tags" => Enum.join(enrollment.tags, ",")
           }),
         {:ok, credential} <- PlcRemote.Tailscale.Enrollment.new(enrollment.auth_key),
         {:ok, candidate_identity, _ipv4} <- PlcRemote.Tailscale.enroll(credential, candidate),
         {:ok, _rollback} <- PlcRemote.Tailscale.commit_enrollment(candidate_identity),
         {:ok, settings} <-
           PlcRemote.Configuration.complete_enrollment(%{
             "tailscale_enabled" => "true",
             "tailscale_hostname" => enrollment.hostname,
             "tailscale_tags" => Enum.join(enrollment.tags, ",")
           }) do
      {:ok,
       %{
         auth_payload_removed: not File.exists?(payload_path),
         tailscale: settings.tailscale
       }}
    end
  end

  @spec await_tailnet(non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def await_tailnet(timeout_ms \\ 180_000) do
    await(fn -> connected_tailnet(PlcRemote.Tailscale.status()) end, timeout_ms)
  end

  defp connected_tailnet(%{lifecycle: :connected} = status) do
    case tailnet_identity() do
      {:ok, identity} -> {:ok, %{identity: identity, lifecycle: :connected, status: status}}
      _error -> :retry
    end
  end

  defp connected_tailnet(_status), do: :retry

  @spec record_tailnet_identity() :: {:ok, map()} | {:error, term()}
  def record_tailnet_identity do
    with {:ok, identity} <- tailnet_identity(),
         true <- is_binary(identity.stable_id),
         :ok <- File.mkdir_p(Path.dirname(@tailnet_identity_path)),
         {:ok, encoded} <- Jason.encode(identity),
         :ok <- File.write(@tailnet_identity_path, encoded, [:binary, :sync]),
         :ok <- File.chmod(@tailnet_identity_path, 0o600) do
      {:ok, %{identity: identity, identity_recorded: true}}
    else
      false -> {:error, :tailnet_identity_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @spec verify_tailnet_identity() :: {:ok, map()} | {:error, term()}
  def verify_tailnet_identity do
    with {:ok, encoded} <- File.read(@tailnet_identity_path),
         {:ok, expected} <- Jason.decode(encoded),
         {:ok, current} <- tailnet_identity(),
         true <- is_binary(current.stable_id),
         true <- expected["stable_id"] == current.stable_id do
      {:ok, %{identity: current, identity_persisted: true}}
    else
      false -> {:error, :tailnet_identity_changed}
      {:error, _reason} = error -> error
    end
  end

  @spec schedule_poweroff() :: :ok
  def schedule_poweroff do
    spawn(fn ->
      Process.sleep(250)
      Nerves.Runtime.poweroff()
    end)

    :ok
  end

  @spec persistent_status() :: map()
  def persistent_status do
    %{
      network: PlcRemote.Network.status(),
      settings: PlcRemote.Configuration.current() |> redacted_settings()
    }
  end

  @spec plc_echo(binary()) :: {:ok, map()} | {:error, term()}
  def plc_echo(payload \\ "plc-remote-qemu") when is_binary(payload) do
    with {:ok, interface} <- interface_by_mac(@plc_mac),
         {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(@plc_address),
             @plc_port,
             [:binary, active: false, packet: :raw, bind_to_device: interface.ifname],
             5_000
           ) do
      try do
        with :ok <- :gen_tcp.send(socket, payload),
             {:ok, ^payload} <- :gen_tcp.recv(socket, byte_size(payload), 5_000) do
          {:ok,
           %{
             destination: "#{@plc_address}:#{@plc_port}",
             ifname: interface.ifname,
             payload: payload
           }}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  @spec nif_smoke() :: {:ok, map()} | {:error, term()}
  def nif_smoke do
    :ok = File.mkdir_p(Path.dirname(@nif_smoke_path))

    case Tailscale.Native.load_key_file(@nif_smoke_path) do
      {:ok, _keys} ->
        protect(@nif_smoke_path)
        {:ok, %{key_file: @nif_smoke_path, nif_loaded: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec result(term()) :: String.t()
  def result(value),
    do: "PLC_REMOTE_CI:" <> inspect(value, limit: :infinity, printable_limit: :infinity)

  defp decode_enrollment(encoded) do
    case Jason.decode(encoded) do
      {:ok, %{"auth_key" => auth_key, "hostname" => hostname, "tags" => tags}}
      when is_binary(auth_key) and is_binary(hostname) and is_list(tags) ->
        auth_key = String.trim(auth_key)

        if auth_key != "" and Enum.all?(tags, &is_binary/1) do
          {:ok, %{auth_key: auth_key, hostname: hostname, tags: tags}}
        else
          {:error, :invalid_enrollment_payload}
        end

      _other ->
        {:error, :invalid_enrollment_payload}
    end
  end

  defp tailnet_identity do
    case GenServer.call(PlcRemote.Tailscale.FSM, :state).payload do
      %{device: nil} ->
        {:error, :tailnet_device_unavailable}

      %{device: device} ->
        with {:ok, node} <- Tailscale.self_node(device) do
          {:ok,
           %{
             hostname: node.hostname,
             stable_id: node.stable_id,
             tailnet_addresses: Enum.map(node.tailnet_addresses, &format_ip/1)
           }}
        end
    end
  catch
    :exit, reason -> {:error, {:tailscale_runtime_unavailable, reason}}
  end

  defp format_ip(address) when is_tuple(address), do: address |> :inet.ntoa() |> to_string()
  defp format_ip(address), do: to_string(address)

  defp await(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(check, deadline)
  end

  defp do_await(check, deadline) do
    case check.() do
      {:ok, _value} = result ->
        result

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(100)
          do_await(check, deadline)
        end
    end
  end

  defp application_running?(application) do
    Enum.any?(Application.started_applications(), &(elem(&1, 0) == application))
  end

  defp interface_by_mac(mac) do
    case Enum.find(interfaces(), &(normalize_mac(&1.mac_address) == mac)) do
      nil -> {:error, {:interface_not_found, mac}}
      interface -> {:ok, interface}
    end
  end

  defp normalize_mac(nil), do: nil
  defp normalize_mac(mac), do: String.downcase(mac)

  defp protect(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp redacted_settings(settings) do
    service = %{settings.service | psk: "[FILTERED]", web_secret: "[FILTERED]"}
    %{settings | service: service}
  end

  defp supervision do
    [
      PlcRemote.Configuration,
      PlcRemote.Health.Reporter,
      PlcRemote.Network.Runtime,
      PlcRemote.Panel.Runtime,
      PlcRemote.Tailscale.Supervisor,
      PlcRemote.Tailscale.Runtime,
      PlcRemote.Service.Supervisor,
      PlcRemote.Service.Runtime,
      PlcRemote.Recovery.Runtime,
      PlcRemote.Firmware.Runtime
    ]
    |> Map.new(&{&1, is_pid(Process.whereis(&1))})
  end
end
