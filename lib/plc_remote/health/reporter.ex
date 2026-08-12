defmodule PlcRemote.Health.Reporter do
  @moduledoc "Owns configuration-derived health facts and managed product alarms."

  use GenServer

  alias PlcRemote.Events.{ConfigurationChanged, ServiceChanged}
  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.{RemoteAccessExpected, RemoteAccessUnavailable}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec service_access() :: PlcRemote.Health.Snapshot.service_access()
  def service_access, do: GenServer.call(__MODULE__, :service_access)

  @impl GenServer
  def init(_opts) do
    :ok = Alarmist.add_managed_alarm(RemoteAccessUnavailable)
    :ok = PlcRemote.Events.subscribe()
    settings = PlcRemote.Configuration.current()
    publish_expectation(settings)
    {:ok, %{settings: settings, service_access: :inactive}}
  end

  @impl GenServer
  def handle_call(:service_access, _from, state), do: {:reply, state.service_access, state}

  @impl GenServer
  def handle_info(%ConfigurationChanged{}, state) do
    settings = PlcRemote.Configuration.current()
    publish_expectation(settings)
    {:noreply, %{state | settings: settings}}
  end

  def handle_info(%ServiceChanged{status: status}, state) do
    access = if status.active, do: :active, else: :inactive
    {:noreply, %{state | service_access: access}}
  end

  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    Alarm.clear(RemoteAccessExpected)
    :ok
  end

  defp publish_expectation(settings) do
    expected? = settings.commissioned and settings.tailscale.enabled

    Alarm.report(RemoteAccessExpected, expected?, %{
      commissioned: settings.commissioned,
      tailscale_enabled: settings.tailscale.enabled
    })
  end
end
