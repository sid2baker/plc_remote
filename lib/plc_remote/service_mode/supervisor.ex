defmodule PlcRemote.ServiceMode.Supervisor do
  @moduledoc """
  Owns the commissioning access point and its local web server.

  The `:one_for_all` strategy prevents either process from surviving without
  the other. In particular, a service-mode crash cannot leave a stale Bandit
  listener that blocks automatic commissioning from restarting.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      PlcRemote.ServiceMode.WebRuntimeSupervisor,
      PlcRemote.ServiceMode.WebSupervisor,
      PlcRemote.ServiceMode
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
