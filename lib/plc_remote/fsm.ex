defmodule PlcRemote.FSM do
  @moduledoc false

  @spec transition(GenServer.name(), atom(), term()) :: Finitomata.State.t()
  def transition(name, event, payload) do
    GenServer.cast(name, {event, payload})
    state(name)
  end

  @spec state(GenServer.name()) :: Finitomata.State.t()
  def state(name), do: GenServer.call(name, :state)

  @spec payload(GenServer.name()) :: term()
  def payload(name), do: state(name).payload

  @spec lifecycle(GenServer.name()) :: atom()
  def lifecycle(name), do: state(name).current

  @spec cancel_timer(reference() | nil) :: :ok
  def cancel_timer(timer), do: PlcRemote.Clock.cancel(timer)
end
