defmodule PlcRemote.Events do
  @moduledoc """
  Typed, local domain-event publication for the single-node appliance.

  Events describe facts that happened. They are not commands and never contain
  credentials.
  """

  @server PlcRemote.PubSub
  @topic "plc_remote:domain_events"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@server, @topic)

  @spec publish(struct()) :: :ok
  def publish(%_{} = event), do: Phoenix.PubSub.broadcast(@server, @topic, event)
end
