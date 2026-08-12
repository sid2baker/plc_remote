defmodule PlcRemote.Proxy.Policy do
  @moduledoc "Pure listener policy for the one fixed isolated-PLC destination."

  @doc "Returns the active PLC interface only when the fixed listener may open."
  @spec machine_ifname(PlcRemote.Settings.t(), PlcRemote.Network.Status.t() | map()) ::
          String.t() | nil
  def machine_ifname(
        %{machine: %{enabled: true}},
        %{applied: true, last_error: nil, roles: %{machine_lan: ifname}}
      )
      when is_binary(ifname),
      do: ifname

  def machine_ifname(_settings, _network_status), do: nil
end
