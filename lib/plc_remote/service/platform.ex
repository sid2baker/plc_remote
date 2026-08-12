defmodule PlcRemote.Service.Platform do
  @moduledoc false

  alias PlcRemote.Network

  @spec enter_access_point(map(), String.t(), String.t(), :open | :wpa2) ::
          :ok | {:error, term()}
  def enter_access_point(service, ssid, regulatory_domain, security) do
    config = Network.service_access_point_config(service, ssid, regulatory_domain, security)
    ifname = Network.interface(:service_ap)
    adapter = network_adapter()

    with :ok <- adapter.configure(ifname, config, persist: false) do
      adapter.wait_for_address(ifname, service.address, 20_000)
    end
  end

  @spec leave_access_point() :: :ok | {:error, term()}
  def leave_access_point do
    network_adapter().configure(
      Network.interface(:service_ap),
      %{type: VintageNetWiFi},
      persist: false
    )
  end

  @spec serial_number() :: String.t()
  def serial_number, do: device_adapter().serial_number()

  @spec web_bind(map()) :: {:inet.ip_address() | :loopback, :inet.port_number()}
  def web_bind(service), do: device_adapter().service_web_bind(service)

  defp network_adapter, do: Application.fetch_env!(:plc_remote, :network_adapter)
  defp device_adapter, do: Application.fetch_env!(:plc_remote, :device_adapter)
end
