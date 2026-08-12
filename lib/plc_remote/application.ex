defmodule PlcRemote.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      PlcRemote.Configuration,
      {Phoenix.PubSub, name: PlcRemote.PubSub},
      PlcRemote.Health.Reporter,
      PlcRemote.Network.Runtime,
      PlcRemote.Tailscale.Supervisor,
      PlcRemote.Service.Supervisor,
      PlcRemote.Recovery.Runtime,
      PlcRemote.Firmware.Runtime
    ]

    Supervisor.start_link(children,
      strategy: :rest_for_one,
      name: PlcRemote.Supervisor
    )
  end
end
