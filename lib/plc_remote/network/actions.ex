defmodule PlcRemote.Network.Actions do
  @moduledoc "Effect ordering for fail-closed network plans."

  alias PlcRemote.Network.Plan

  @spec apply(Plan.t()) :: :ok | {:error, term()}
  def apply(%Plan{} = plan) do
    with :ok <- configure_all(plan.disable, :continue),
         :ok <- planning_result(plan) do
      configure_all(plan.enable, :halt)
    end
  end

  @spec disable(PlcRemote.Network.ifname()) :: :ok | {:error, term()}
  def disable(ifname), do: configure(ifname, PlcRemote.Network.disabled_ethernet_config())

  defp planning_result(%Plan{error: nil}), do: :ok
  defp planning_result(%Plan{error: reason}), do: {:error, reason}

  defp configure_all(configurations, failure_mode) do
    Enum.reduce_while(configurations, :ok, fn {ifname, config}, result ->
      case configure(ifname, config) do
        :ok -> {:cont, result}
        {:error, _reason} = error when failure_mode == :halt -> {:halt, error}
        {:error, _reason} = error when result == :ok -> {:cont, error}
        {:error, _reason} -> {:cont, result}
      end
    end)
  end

  defp configure(ifname, config), do: adapter().configure(ifname, config, persist: false)
  defp adapter, do: Application.fetch_env!(:plc_remote, :network_adapter)
end
