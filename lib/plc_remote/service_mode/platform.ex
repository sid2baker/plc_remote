defmodule PlcRemote.ServiceMode.Platform do
  @moduledoc false

  alias PlcRemote.Network

  @spec open_gpio(String.t()) :: {:ok, term(), term()} | {:error, term()}
  def open_gpio(gpio_spec), do: gpio_adapter().open(gpio_spec)

  @spec close_gpio(term()) :: :ok
  def close_gpio(gpio), do: gpio_adapter().close(gpio)

  @spec read_gpio(term()) :: 0 | 1
  def read_gpio(gpio), do: gpio_adapter().read(gpio)

  @spec enter_access_point(map(), String.t(), String.t(), :open | :wpa2) ::
          :ok | {:error, term()}
  def enter_access_point(service, ssid, regulatory_domain, security) do
    config = Network.service_access_point_config(service, ssid, regulatory_domain, security)

    ifname = Network.interface(:wifi_uplink)
    adapter = network_adapter()

    with :ok <- adapter.configure(ifname, config, persist: false) do
      adapter.wait_for_address(ifname, service.address, 20_000)
    end
  end

  @spec leave_access_point() :: :ok
  def leave_access_point do
    PlcRemote.NetworkManager.restore_wifi()
  end

  @spec serial_number() :: String.t()
  def serial_number, do: device_adapter().serial_number()

  @spec web_bind(map()) :: {:inet.ip_address() | :loopback, :inet.port_number()}
  def web_bind(service), do: device_adapter().service_web_bind(service)

  defp network_adapter, do: Application.fetch_env!(:plc_remote, :network_adapter)
  defp gpio_adapter, do: Application.fetch_env!(:plc_remote, :gpio_adapter)
  defp device_adapter, do: Application.fetch_env!(:plc_remote, :device_adapter)
end
