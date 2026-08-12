defmodule PlcRemote.Recovery.Status do
  @moduledoc "Non-secret staged-recovery lifecycle and persistent reboot budget."

  @type lifecycle ::
          :healthy
          | :outage_observed
          | :reconnect
          | :network_reapply
          | :uplink_cycle
          | :tailscale_restart
          | :reboot
          | :reboot_suppressed
          | :exhausted

  @enforce_keys [
    :lifecycle,
    :consecutive_reboots,
    :last_action,
    :last_action_ago_seconds,
    :offline_for_seconds,
    :stable_for_seconds
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          consecutive_reboots: non_neg_integer(),
          last_action: atom() | nil,
          last_action_ago_seconds: non_neg_integer() | nil,
          offline_for_seconds: non_neg_integer() | nil,
          stable_for_seconds: non_neg_integer() | nil
        }
end
