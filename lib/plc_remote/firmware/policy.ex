defmodule PlcRemote.Firmware.Policy do
  @moduledoc "Pure OTA validation and rollback policy."

  @type decision :: :validate | :revert | :wait

  @doc "Validates an uncommissioned candidate after service and network evidence."
  @spec uncommissioned(map()) :: decision()
  def uncommissioned(%{active: true, network_observed: true}), do: :validate
  def uncommissioned(_service_status), do: :wait

  @doc "Evaluates a commissioned candidate from stable connectivity evidence."
  @spec commissioned(map(), map(), integer() | nil, integer() | nil, integer() | nil, keyword()) ::
          decision()
  def commissioned(tailscale, network, tailnet_ms, internet_without_tail_ms, unreachable_ms, opts) do
    cond do
      tailscale.state == :connected and network.connection == :internet and
          elapsed?(tailnet_ms, Keyword.fetch!(opts, :tailnet_stable_ms)) ->
        :validate

      network.connection == :internet and
          elapsed?(internet_without_tail_ms, Keyword.fetch!(opts, :internet_without_tail_ms)) ->
        :revert

      Keyword.get(opts, :remote_expected, false) and
          elapsed?(unreachable_ms, Keyword.fetch!(opts, :candidate_unreachable_ms)) ->
        :revert

      true ->
        :wait
    end
  end

  defp elapsed?(nil, _threshold), do: false
  defp elapsed?(elapsed, threshold), do: elapsed >= threshold
end
