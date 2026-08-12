defmodule PlcRemote.Recovery.RebootBudget do
  @moduledoc "Persistent consecutive automatic-reboot budget."

  alias PlcRemote.Recovery.Store

  @spec load(Path.t() | nil) :: non_neg_integer()
  def load(path), do: Store.load(path).consecutive_reboots

  @spec set(Path.t() | nil, non_neg_integer()) :: :ok | {:error, term()}
  def set(path, count), do: Store.save(path, %{consecutive_reboots: count})
end
