defmodule PlcRemote.RetryPolicy do
  @moduledoc """
  Bounded exponential retry delays with fleet-friendly jitter.

  Fast initial retries recover from ordinary DHCP and boot ordering races. The
  delay then grows to five minutes so a site outage does not create a tight
  reconnect loop or synchronize a fleet against the control plane.
  """

  @delays_ms [5_000, 15_000, 30_000, 60_000, 120_000, 300_000]

  @doc "Returns the base delay for a one-based consecutive failure count."
  @spec base_delay(pos_integer()) :: pos_integer()
  def base_delay(failure_count) when failure_count > 0 do
    Enum.at(@delays_ms, failure_count - 1, List.last(@delays_ms))
  end

  @doc "Adds up to ±20 percent jitter to the base delay."
  @spec delay(pos_integer()) :: pos_integer()
  def delay(failure_count) do
    base = base_delay(failure_count)
    jitter = :rand.uniform(41) - 21
    max(div(base * (100 + jitter), 100), 1_000)
  end
end
