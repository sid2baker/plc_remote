defmodule PlcRemote.Service.Router do
  @moduledoc "Tightly scoped service-WLAN Internet forwarding."

  @service_ifname "wlan0"

  @spec enable(PlcRemote.Settings.t()) :: :ok | {:error, term()}
  def enable(settings) do
    with {:ok, wan} <- internet_ifname(settings) do
      platform().enable(@service_ifname, wan, settings.service)
    end
  end

  @spec disable() :: :ok | {:error, term()}
  def disable, do: platform().disable()

  defp internet_ifname(_settings) do
    case PlcRemote.Network.status().roles.internet_uplink do
      ifname when is_binary(ifname) -> {:ok, ifname}
      _missing -> {:error, :internet_uplink_unavailable}
    end
  catch
    :exit, _reason -> {:error, :internet_uplink_unavailable}
  end

  defp platform do
    Application.fetch_env!(:plc_remote, :service_router_adapter)
  end
end
