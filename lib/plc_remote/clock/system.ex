defmodule PlcRemote.Clock.System do
  @moduledoc false
  @behaviour PlcRemote.Clock

  @impl true
  def now_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def send_after(pid, event, delay_ms), do: Process.send_after(pid, event, delay_ms)

  @impl true
  def cancel(nil), do: :ok

  def cancel(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end
end
