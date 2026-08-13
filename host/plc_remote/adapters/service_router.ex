defmodule PlcRemote.Adapters.Host.ServiceRouter do
  @moduledoc false

  @behaviour PlcRemote.Adapters.ServiceRouter

  @impl true
  def enable(_service_ifname, _wan_ifname, _service), do: :ok

  @impl true
  def disable, do: :ok
end
