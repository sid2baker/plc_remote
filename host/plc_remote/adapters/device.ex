defmodule PlcRemote.Adapters.Host.Device do
  @moduledoc false

  @behaviour PlcRemote.Adapters.Device

  @impl true
  def serial_number, do: "HOST"

  @impl true
  def service_web_bind(_service) do
    {:loopback, Application.get_env(:plc_remote, :service_port, 4_000)}
  end
end
