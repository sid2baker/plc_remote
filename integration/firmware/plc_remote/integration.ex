defmodule PlcRemote.Integration do
  @moduledoc false

  @wan_mac "02:00:00:00:00:10"
  @plc_mac "02:00:00:00:00:20"
  @plc_address "192.168.10.100"
  @plc_port 10_102
  @nif_smoke_path "/data/plc_remote/integration/nif-smoke.json"

  @spec health() :: map()
  def health do
    %{
      application: application_running?(:plc_remote),
      network: safe_status(PlcRemote.NetworkManager),
      service: safe_status(PlcRemote.ServiceMode),
      supervision: supervision(),
      tailscale: safe_status(PlcRemote.TailscaleManager)
    }
  end

  @spec interfaces() :: [map()]
  def interfaces do
    PlcRemote.NetworkManager.status().interfaces
  end

  @spec provision_ethernet_roles() :: {:ok, map()} | {:error, term()}
  def provision_ethernet_roles do
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
             "recovery_auto_reboot" => "false"
           }),
         :ok <- PlcRemote.NetworkManager.reapply() do
      {:ok,
       %{
         settings: redacted_settings(settings),
         status: PlcRemote.NetworkManager.status()
       }}
    end
  end

  @spec await_connection(atom(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def await_connection(expected, timeout_ms \\ 30_000) do
    await(
      fn ->
        status = PlcRemote.NetworkManager.status()
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
      network: PlcRemote.NetworkManager.status(),
      settings: PlcRemote.Configuration.get() |> redacted_settings()
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

  defp safe_status(module) do
    module.status()
  catch
    :exit, reason -> %{error: inspect(reason)}
  end

  defp supervision do
    [
      PlcRemote.Configuration,
      PlcRemote.NetworkManager,
      PlcRemote.TailscaleSupervisor,
      PlcRemote.TailscaleManager,
      PlcRemote.ServiceMode.Supervisor,
      PlcRemote.ServiceMode,
      PlcRemote.RecoveryManager,
      PlcRemote.FirmwareValidator
    ]
    |> Map.new(&{&1, is_pid(Process.whereis(&1))})
  end
end
