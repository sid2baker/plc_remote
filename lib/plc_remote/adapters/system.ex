defmodule PlcRemote.Adapters.System do
  @moduledoc """
  Boundary for reboot and A/B firmware-slot operations.

  Keeping these target-only effects behind an adapter makes recovery policy
  deterministic and testable on the host.
  """

  @callback init_complete() :: :ok
  @callback firmware_validation_status() :: :validated | :unvalidated | :unknown
  @callback validate_firmware() :: :ok | {:error, term()}
  @callback revert_firmware() :: :ok | {:error, term()} | no_return()
  @callback reboot() :: :ok | no_return()
end
