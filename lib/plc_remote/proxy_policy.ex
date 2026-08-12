defmodule PlcRemote.ProxyPolicy do
  @moduledoc false

  @doc "Returns the active PLC interface only when the fixed listener may open."
  @spec machine_ifname(map(), map()) :: String.t() | nil
  def machine_ifname(
        %{machine: %{enabled: true}},
        %{last_error: nil, roles: %{machine_lan: ifname}}
      )
      when is_binary(ifname),
      do: ifname

  def machine_ifname(_settings, _network_status), do: nil
end
