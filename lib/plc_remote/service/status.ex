defmodule PlcRemote.Service.Status do
  @moduledoc "Non-secret operational status for setup and protected recovery access."

  @type lifecycle ::
          :inactive
          | :starting_automatic
          | :automatic
          | :verifying_automatic
          | :starting_recovery
          | :recovery
          | :verifying_recovery
          | :fault

  @enforce_keys [
    :lifecycle,
    :active,
    :address,
    :expires_in_seconds,
    :gpio_error,
    :gpio_spec,
    :secured,
    :ssid,
    :verification
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          active: boolean(),
          address: String.t(),
          expires_in_seconds: non_neg_integer() | nil,
          gpio_error: PlcRemote.Error.t() | nil,
          gpio_spec: String.t(),
          secured: boolean(),
          ssid: String.t() | nil,
          verification: PlcRemote.Service.Verification.t()
        }
end
