defmodule PlcRemote.Health.Snapshot do
  @moduledoc "A non-secret read model of current appliance health conditions."

  @type availability :: :available | :unavailable
  @type lifecycle :: :disabled | :connected | :disconnected
  @type service_access :: :active | :inactive | :unavailable
  @type firmware :: :validated | :unvalidated | :validation_failed | :unknown

  @enforce_keys [
    :internet,
    :plc_interface,
    :tailscale,
    :remote_access,
    :service_access,
    :firmware,
    :alarms
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          internet: availability(),
          plc_interface: availability(),
          tailscale: lifecycle(),
          remote_access: availability(),
          service_access: service_access(),
          firmware: firmware(),
          alarms: [Alarmist.alarm_id()]
        }
end
