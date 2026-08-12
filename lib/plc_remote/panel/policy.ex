defmodule PlcRemote.Panel.Policy do
  @moduledoc "Pure IPCBOX indicator and output policy."

  @type levels :: %{
          output_1: 0 | 1,
          output_2: 0 | 1,
          user_1: 0 | 1,
          user_2: 0 | 1
        }

  @doc "Returns physical GPIO levels. Every output defaults to its fail-safe off state."
  @spec levels(
          PlcRemote.Network.Status.t() | nil,
          PlcRemote.Tailscale.Status.t() | nil,
          PlcRemote.Service.Status.t() | nil
        ) :: levels()
  def levels(network, tailscale, service) do
    %{
      output_1: bool(remote_plc_ready?(network, tailscale)),
      output_2: bool(service_active?(service)),
      user_1: active_low(remote_access_unavailable?(tailscale)),
      user_2: active_low(service_fault?(service))
    }
  end

  defp remote_plc_ready?(%{applied: true, last_error: nil, roles: %{machine_lan: ifname}}, %{
         lifecycle: :connected,
         listener: :active
       })
       when is_binary(ifname),
       do: true

  defp remote_plc_ready?(_network, _tailscale), do: false

  defp remote_access_unavailable?(%{lifecycle: lifecycle})
       when lifecycle in [:waiting_for_network, :connecting, :retry_wait],
       do: true

  defp remote_access_unavailable?(_tailscale), do: false
  defp service_active?(%{active: active}), do: active
  defp service_active?(_service), do: false
  defp service_fault?(%{lifecycle: :fault}), do: true
  defp service_fault?(%{gpio_error: error}), do: not is_nil(error)
  defp service_fault?(_service), do: false
  defp bool(true), do: 1
  defp bool(false), do: 0
  defp active_low(true), do: 0
  defp active_low(false), do: 1
end
