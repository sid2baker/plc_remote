defmodule PlcRemote.Adapters.Device do
  @moduledoc false

  @callback serial_number() :: String.t()
  @callback service_web_bind(map()) :: {:inet.ip_address() | :loopback, :inet.port_number()}
end
