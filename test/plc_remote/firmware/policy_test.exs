defmodule PlcRemote.Firmware.PolicyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.Firmware.Policy

  @options [
    tailnet_stable_ms: 60_000,
    internet_without_tail_ms: 2_700_000,
    remote_expected: false,
    candidate_unreachable_ms: 2_700_000
  ]

  test "uncommissioned firmware validates only after the automatic AP is healthy" do
    assert Policy.uncommissioned(%{active: true, mode: :automatic}) == :validate
    assert Policy.uncommissioned(%{active: true, mode: :recovery}) == :wait
    assert Policy.uncommissioned(%{active: false, mode: nil}) == :wait
  end

  test "commissioned firmware validates after stable tailnet connectivity" do
    tailscale = %{state: :connected}
    network = %{connection: :internet}

    assert Policy.commissioned(tailscale, network, 59_999, nil, nil, @options) == :wait
    assert Policy.commissioned(tailscale, network, 60_000, nil, nil, @options) == :validate
  end

  test "rollback requires working Internet and prolonged Tailscale failure" do
    tailscale = %{state: :error}

    assert Policy.commissioned(
             tailscale,
             %{connection: :internet},
             nil,
             2_700_000,
             nil,
             @options
           ) == :revert

    assert Policy.commissioned(
             tailscale,
             %{connection: :disconnected},
             nil,
             9_000_000,
             nil,
             @options
           ) == :wait
  end

  test "pre-update evidence permits rollback even when candidate loses all Internet" do
    options = Keyword.put(@options, :remote_expected, true)

    assert Policy.commissioned(
             %{state: :error},
             %{connection: :disconnected},
             nil,
             nil,
             2_700_000,
             options
           ) == :revert
  end
end
