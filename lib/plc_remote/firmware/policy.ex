defmodule PlcRemote.Firmware.Policy do
  @moduledoc """
  Pure validation and rollback decisions for tentative firmware.
  """

  @type decision :: :wait | :validate | :revert

  @doc "Evaluates an uncommissioned candidate from service-mode health."
  @spec uncommissioned(map()) :: decision()
  def uncommissioned(%{active: true, mode: :automatic}), do: :validate
  def uncommissioned(_service_status), do: :wait

  @doc "Evaluates a commissioned candidate from stable connectivity evidence."
  @spec commissioned(
          map(),
          map(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          keyword()
        ) :: decision()
  def commissioned(
        tailscale,
        network,
        tailnet_elapsed,
        internet_elapsed,
        candidate_unreachable_elapsed,
        opts
      ) do
    tailnet_required = Keyword.fetch!(opts, :tailnet_stable_ms)
    internet_limit = Keyword.fetch!(opts, :internet_without_tail_ms)
    remote_expected? = Keyword.fetch!(opts, :remote_expected)
    candidate_limit = Keyword.fetch!(opts, :candidate_unreachable_ms)

    cond do
      tailnet_stable?(tailscale, tailnet_elapsed, tailnet_required) ->
        :validate

      internet_regression?(tailscale, network, internet_elapsed, internet_limit) ->
        :revert

      expected_remote_regression?(
        tailscale,
        remote_expected?,
        candidate_unreachable_elapsed,
        candidate_limit
      ) ->
        :revert

      true ->
        :wait
    end
  end

  defp tailnet_stable?(tailscale, elapsed, required) do
    tailscale[:state] == :connected and elapsed?(elapsed, required)
  end

  defp internet_regression?(tailscale, network, elapsed, limit) do
    tailscale[:state] != :connected and network[:connection] == :internet and
      elapsed?(elapsed, limit)
  end

  defp expected_remote_regression?(tailscale, remote_expected?, elapsed, limit) do
    tailscale[:state] != :connected and remote_expected? and elapsed?(elapsed, limit)
  end

  defp elapsed?(nil, _required), do: false
  defp elapsed?(elapsed, required), do: elapsed >= required
end
