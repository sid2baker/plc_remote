defmodule PlcRemote.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      PlcRemote.Configuration,
      PlcRemote.NetworkManager,
      PlcRemote.TailscaleSupervisor,
      PlcRemote.ServiceMode.Supervisor,
      PlcRemote.RecoveryManager,
      PlcRemote.FirmwareValidator
    ]

    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: PlcRemote.Supervisor
    )
  end
end
