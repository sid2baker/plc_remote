defmodule PlcRemote.Firmware.State do
  @moduledoc false

  @enforce_keys [:runtime, :settings, :expectation_path]
  defstruct runtime: nil,
            settings: nil,
            expectation_path: nil,
            validation: :unknown,
            remote_expected: false,
            network_observed: false,
            tailnet_stable_since: nil,
            internet_without_tail_since: nil,
            candidate_unreachable_since: nil,
            last_action: nil,
            last_error: nil

  @type t :: %__MODULE__{
          runtime: pid(),
          settings: PlcRemote.Settings.t(),
          expectation_path: Path.t() | nil,
          validation: :validated | :unvalidated | :unknown,
          remote_expected: boolean(),
          network_observed: boolean(),
          tailnet_stable_since: integer() | nil,
          internet_without_tail_since: integer() | nil,
          candidate_unreachable_since: integer() | nil,
          last_action: atom() | nil,
          last_error: PlcRemote.Error.t() | nil
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(state, opts) do
      safe =
        state
        |> Map.from_struct()
        |> Map.drop([:runtime, :settings])

      concat(["#PlcRemote.Firmware.State<", to_doc(safe, opts), ">"])
    end
  end
end
