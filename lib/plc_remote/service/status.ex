defmodule PlcRemote.Service.Status do
  @moduledoc "Operational status for the continuously requested service WLAN."

  @type lifecycle :: :inactive | :active | :fault

  @enforce_keys [
    :lifecycle,
    :active,
    :address,
    :gpio_asserted,
    :gpio_error,
    :gpio_spec,
    :routing,
    :secured,
    :ssid
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          active: boolean(),
          address: String.t(),
          gpio_asserted: boolean() | :unknown,
          gpio_error: PlcRemote.Error.t() | nil,
          gpio_spec: String.t(),
          routing: :inactive | :active | :unavailable,
          secured: true,
          ssid: String.t() | nil
        }
end
