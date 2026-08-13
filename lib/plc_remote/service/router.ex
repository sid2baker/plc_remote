defmodule PlcRemote.Service.Router do
  @moduledoc "Tightly scoped service-WLAN Internet forwarding."

  @service_ifname "wlan0"

  @spec enable() :: :ok | {:error, term()}
  def enable do
    case PlcRemote.Network.status().roles.internet_uplink do
      wan_ifname when is_binary(wan_ifname) ->
        platform().enable(@service_ifname, wan_ifname)

      _missing ->
        {:error, :internet_uplink_unavailable}
    end
  catch
    :exit, _reason -> {:error, :internet_uplink_unavailable}
  end

  @spec disable() :: :ok | {:error, term()}
  def disable, do: platform().disable()

  defp platform do
    Application.fetch_env!(:plc_remote, :service_router_adapter)
  end
end
