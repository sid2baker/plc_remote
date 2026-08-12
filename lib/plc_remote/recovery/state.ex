defmodule PlcRemote.Recovery.State do
  @moduledoc false

  @enforce_keys [:runtime, :settings, :path, :consecutive_reboots]
  defstruct runtime: nil,
            settings: nil,
            path: nil,
            consecutive_reboots: 0,
            firmware_validation: :unknown,
            offline_since: nil,
            stable_since: nil,
            last_action: nil,
            last_action_at: nil,
            last_error: nil

  @type t :: %__MODULE__{
          runtime: pid(),
          settings: PlcRemote.Settings.t(),
          path: Path.t() | nil,
          consecutive_reboots: non_neg_integer(),
          firmware_validation: :validated | :unvalidated | :unknown,
          offline_since: integer() | nil,
          stable_since: integer() | nil,
          last_action: atom() | nil,
          last_action_at: integer() | nil,
          last_error: PlcRemote.Error.t() | nil
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(state, opts) do
      safe =
        state
        |> Map.from_struct()
        |> Map.drop([:runtime, :settings])

      concat(["#PlcRemote.Recovery.State<", to_doc(safe, opts), ">"])
    end
  end
end
