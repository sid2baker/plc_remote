defmodule PlcRemote.Adapters.Host.Network do
  @moduledoc false

  @behaviour PlcRemote.Adapters.Network

  @impl true
  def configure(_ifname, _config, _opts), do: :ok

  @impl true
  def wait_for_address(_ifname, _address, _timeout), do: :ok

  @impl true
  def connection_status, do: Application.get_env(:plc_remote, :host_connection_status, :internet)

  @impl true
  def interfaces do
    [
      %{
        ifname: "eth0",
        hw_path: "/devices/host/native-gigabit",
        kind: :ethernet,
        driver: "macb",
        speed_mbps: 1_000,
        lower_up: true,
        connection: :lan,
        mac_address: "02:00:00:00:00:10",
        addresses: ["192.168.10.1/24"]
      },
      %{
        ifname: "eth1",
        hw_path: "/devices/host/usb-2.5-gigabit",
        kind: :ethernet,
        driver: "r8152",
        speed_mbps: 2_500,
        lower_up: true,
        connection: :internet,
        mac_address: "02:00:00:00:00:25",
        addresses: ["192.168.1.25/24"]
      },
      %{
        ifname: "wlan0",
        hw_path: "/devices/host/wifi",
        kind: :wifi,
        driver: "brcmfmac",
        speed_mbps: nil,
        lower_up: false,
        connection: :disconnected,
        mac_address: "02:00:00:00:00:50",
        addresses: ["192.168.50.1/24"]
      }
    ]
  end
end
