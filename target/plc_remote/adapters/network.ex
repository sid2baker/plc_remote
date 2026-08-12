defmodule PlcRemote.Adapters.Target.Network do
  @moduledoc """
  Serialized VintageNet boundary for target firmware.

  The Wi-Fi interface is reserved for the commissioning and recovery access
  point. Normal Internet connectivity is Ethernet-only.
  """

  @behaviour PlcRemote.Adapters.Network

  @configure_timeout_ms 15_000
  @poll_interval_ms 25

  @impl true
  def configure(ifname, config, opts) do
    lock = {{__MODULE__, ifname}, self()}

    case :global.trans(lock, fn ->
           with :ok <- wait_until_configurable(ifname, @configure_timeout_ms) do
             VintageNet.configure(ifname, config, opts)
           end
         end) do
      :aborted -> {:error, :configure_lock_aborted}
      {:aborted, reason} -> {:error, {:configure_lock_aborted, reason}}
      result -> result
    end
  catch
    :exit, reason -> {:error, {:configure_exit, reason}}
  end

  @impl true
  def wait_for_address(ifname, address, timeout) do
    with {:ok, parsed_address} <- parse_address(address) do
      wait_until(fn -> address_present?(ifname, parsed_address) end, timeout, :address_timeout)
    end
  end

  @impl true
  def connection_status, do: VintageNet.get(["connection"])

  @impl true
  def interfaces do
    ["interface", :_, "hw_path"]
    |> VintageNet.match()
    |> Enum.map(fn {["interface", ifname, "hw_path"], hw_path} ->
      %{
        ifname: ifname,
        hw_path: hw_path,
        kind: interface_kind(ifname),
        driver: driver(ifname),
        speed_mbps: speed_mbps(ifname),
        lower_up: VintageNet.get(["interface", ifname, "lower_up"]),
        connection: VintageNet.get(["interface", ifname, "connection"]),
        mac_address: VintageNet.get(["interface", ifname, "mac_address"])
      }
    end)
    |> Enum.reject(&(&1.hw_path == "/devices/virtual"))
    |> Enum.sort_by(& &1.ifname)
  end

  defp wait_until_configurable(ifname, timeout) do
    wait_until(
      fn -> VintageNet.get(["interface", ifname, "state"]) != :reconfiguring end,
      timeout,
      :interface_busy
    )
  end

  defp address_present?(ifname, address) do
    ifname
    |> then(&VintageNet.get(["interface", &1, "addresses"]))
    |> List.wrap()
    |> Enum.any?(&(&1.address == address))
  end

  defp wait_until(predicate, timeout, timeout_reason) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(predicate, deadline, timeout_reason)
  end

  defp do_wait_until(predicate, deadline, timeout_reason) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, timeout_reason}

      true ->
        Process.sleep(@poll_interval_ms)
        do_wait_until(predicate, deadline, timeout_reason)
    end
  end

  defp parse_address(address), do: :inet.parse_ipv4_address(String.to_charlist(address))

  defp interface_kind("usb0"), do: :recovery
  defp interface_kind("eth" <> _suffix), do: :ethernet
  defp interface_kind("wlan" <> _suffix), do: :wifi
  defp interface_kind(_ifname), do: :other

  defp driver(ifname) do
    case File.read_link("/sys/class/net/#{ifname}/device/driver") do
      {:ok, path} -> Path.basename(path)
      {:error, _reason} -> nil
    end
  end

  defp speed_mbps(ifname) do
    with {:ok, value} <- File.read("/sys/class/net/#{ifname}/speed"),
         {speed, _suffix} when speed > 0 <- Integer.parse(value) do
      speed
    else
      _other -> nil
    end
  end
end
