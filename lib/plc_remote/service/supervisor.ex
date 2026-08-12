defmodule PlcRemote.Service.Supervisor do
  @moduledoc "Owns Phoenix runtime, temporary Bandit listener, GPIO runtime, and Service FSM."

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      PlcRemote.Service.WebRuntimeSupervisor,
      PlcRemote.Service.WebSupervisor,
      PlcRemote.Service.Runtime
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
