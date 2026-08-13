defmodule PlcRemote.Integration.ServiceAP do
  @moduledoc false

  @spec activate_service_access_point(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def activate_service_access_point(service, _ssid, _regulatory_domain) do
    address = "#{service.address}/#{service.prefix_length}"

    case System.cmd("ip", ["address", "replace", address, "dev", "lo"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:emulated_service_address, status, String.trim(output)}}
    end
  end
end
