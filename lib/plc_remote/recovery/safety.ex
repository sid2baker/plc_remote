defmodule PlcRemote.Recovery.Safety do
  @moduledoc """
  Pure escape-hatch checks that must pass before an automatic reboot.
  """

  @doc "Returns `:ok` only when the persistent reboot budget may be consumed."
  @spec reboot_allowed?(map(), :validated | :unvalidated | :unknown, non_neg_integer()) ::
          :ok | {:error, atom()}
  def reboot_allowed?(recovery, firmware_status, consecutive_reboots) do
    cond do
      not recovery.auto_reboot ->
        {:error, :disabled}

      firmware_status == :unvalidated ->
        {:error, :firmware_unvalidated}

      consecutive_reboots >= recovery.max_consecutive_reboots ->
        {:error, :budget_exhausted}

      true ->
        :ok
    end
  end
end
