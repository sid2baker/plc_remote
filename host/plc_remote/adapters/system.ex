defmodule PlcRemote.Adapters.Host.System do
  @moduledoc false

  @behaviour PlcRemote.Adapters.System

  @impl true
  def init_complete, do: :ok

  @impl true
  def firmware_validation_status,
    do: Application.get_env(:plc_remote, :host_firmware_validation_status, :validated)

  @impl true
  def validate_firmware, do: :ok

  @impl true
  def revert_firmware, do: :ok

  @impl true
  def reboot, do: :ok
end
