defmodule PlcRemote.Tailscale.Status do
  @moduledoc "Non-secret operational status for embedded Tailscale and the fixed PLC listener."

  @type lifecycle :: :disabled | :waiting_for_network | :connecting | :connected | :retry_wait
  @type listener :: :disabled | :inactive | :active | :unavailable

  @enforce_keys [
    :lifecycle,
    :listener,
    :active_sessions,
    :connected_for_seconds,
    :destination,
    :failure_count,
    :listen_port,
    :last_error,
    :retry_in_seconds,
    :tailnet_ipv4
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          lifecycle: lifecycle(),
          listener: listener(),
          active_sessions: non_neg_integer(),
          connected_for_seconds: non_neg_integer() | nil,
          destination: String.t(),
          failure_count: non_neg_integer(),
          listen_port: :inet.port_number(),
          last_error: PlcRemote.Error.t() | nil,
          retry_in_seconds: non_neg_integer() | nil,
          tailnet_ipv4: String.t() | nil
        }
end
