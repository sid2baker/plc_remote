defmodule PlcRemote.Firmware.Status do
  @moduledoc "Non-secret firmware-slot lifecycle and connectivity evidence."

  @type lifecycle ::
          :initializing
          | :validated
          | :unknown
          | :candidate
          | :validation_failed
          | :revert_requested
          | :revert_failed

  @enforce_keys [
    :lifecycle,
    :validation,
    :candidate_unreachable_seconds,
    :internet_without_tail_seconds,
    :last_action,
    :last_error,
    :remote_expected,
    :tailnet_stable_seconds
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          validation: :validated | :unvalidated | :unknown,
          candidate_unreachable_seconds: non_neg_integer() | nil,
          internet_without_tail_seconds: non_neg_integer() | nil,
          last_action: atom() | nil,
          last_error: PlcRemote.Error.t() | nil,
          remote_expected: boolean(),
          tailnet_stable_seconds: non_neg_integer() | nil
        }
end
