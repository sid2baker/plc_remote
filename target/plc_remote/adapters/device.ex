defmodule PlcRemote.Adapters.Target.Device do
  @moduledoc false

  @behaviour PlcRemote.Adapters.Device

  @impl true
  def serial_number, do: Nerves.Runtime.serial_number()

  @impl true
  def service_web_bind(service) do
    {:ok, address} = :inet.parse_ipv4_address(String.to_charlist(service.address))
    {address, Application.get_env(:plc_remote, :service_port, 80)}
  end
end
