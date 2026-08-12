defmodule PlcRemote.Tailscale.Supervisor do
  @moduledoc """
  Owns connection tasks, fixed-proxy sessions, and the Tailscale FSM runtime.

  `:one_for_all` gives native resources, tasks, runtime event translation, and
  lifecycle one shared failure boundary.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @spec restart_runtime() :: :ok
  def restart_runtime do
    case Process.whereis(PlcRemote.Tailscale.Runtime) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    :ok
  end

  @impl Supervisor
  def init(_opts) do
    network = PlcRemote.Network.status()

    children = [
      {Task.Supervisor, name: PlcRemote.Tailscale.ConnectionSupervisor},
      {Task.Supervisor, name: PlcRemote.Tailscale.SessionSupervisor},
      {PlcRemote.Tailscale.Runtime, network: network}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
