defmodule PlcRemote.Clock do
  @moduledoc "Injectable monotonic clock and process-timer boundary for lifecycle runtimes."

  @callback now_ms() :: integer()
  @callback send_after(pid(), term(), non_neg_integer()) :: reference()
  @callback cancel(reference() | nil) :: :ok

  @spec now_ms() :: integer()
  def now_ms, do: adapter().now_ms()

  @spec send_after(pid(), term(), non_neg_integer()) :: reference()
  def send_after(pid, event, delay_ms), do: adapter().send_after(pid, event, delay_ms)

  @spec cancel(reference() | nil) :: :ok
  def cancel(timer), do: adapter().cancel(timer)

  defp adapter, do: Application.get_env(:plc_remote, :clock_adapter, PlcRemote.Clock.System)
end
