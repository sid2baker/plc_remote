defmodule PlcRemote.TailscaleSupervisor do
  @moduledoc """
  Owns the complete Tailscale runtime boundary.

  A `:one_for_all` strategy ensures that connection tasks, active PLC proxy
  sessions, and the manager share one lifetime. If any child fails, all
  Tailscale resources are torn down before a clean restart.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Forces a clean restart of the complete Tailscale runtime boundary."
  @spec restart_runtime() :: :ok
  def restart_runtime do
    case Process.whereis(PlcRemote.TailscaleManager) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    :ok
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Task.Supervisor, name: PlcRemote.TailscaleConnectionTaskSupervisor},
      {Task.Supervisor, name: PlcRemote.TailscaleSessionTaskSupervisor},
      PlcRemote.TailscaleManager
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
