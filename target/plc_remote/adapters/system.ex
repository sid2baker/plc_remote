defmodule PlcRemote.Adapters.Target.System do
  @moduledoc false

  @behaviour PlcRemote.Adapters.System

  @impl true
  def init_complete do
    Nerves.Runtime.Heart.init_complete()
    :ok
  end

  @impl true
  def firmware_validation_status, do: Nerves.Runtime.firmware_validation_status()

  @impl true
  def validate_firmware, do: Nerves.Runtime.validate_firmware()

  @impl true
  def revert_firmware, do: Nerves.Runtime.revert()

  @impl true
  def reboot, do: Nerves.Runtime.reboot()
end
