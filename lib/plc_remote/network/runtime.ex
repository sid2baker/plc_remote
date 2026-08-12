defmodule PlcRemote.Network.Runtime do
  @moduledoc """
  Owns physical interface discovery and fail-closed Ethernet application.

  The runtime publishes typed status and primitive network alarms. It does not
  decide whether product-level remote access is healthy.
  """

  use GenServer

  require Logger

  alias PlcRemote.Events.{ConfigurationChanged, NetworkChanged}
  alias PlcRemote.Health.Alarm

  alias PlcRemote.Health.Alarms.{
    InternetUnavailable,
    NetworkConfigurationInvalid,
    PlcInterfaceUnavailable
  }

  alias PlcRemote.Network.{Actions, Plan, Status}

  @refresh_interval_ms 5_000
  @owned_alarms [
    InternetUnavailable,
    NetworkConfigurationInvalid,
    PlcInterfaceUnavailable
  ]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec status() :: Status.t()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec reapply() :: :ok | {:error, term()}
  def reapply, do: GenServer.call(__MODULE__, :reapply, 60_000)

  @spec cycle_uplink() :: :ok | {:error, term()}
  def cycle_uplink, do: GenServer.call(__MODULE__, :cycle_uplink, 60_000)

  @impl GenServer
  def init(_opts) do
    :ok = PlcRemote.Events.subscribe()
    settings = PlcRemote.Configuration.current()
    interfaces = interfaces()
    send(self(), :apply_settings)
    schedule_refresh()

    {:ok,
     %{
       settings: settings,
       interfaces: interfaces,
       interface_signature: interface_signature(interfaces),
       last_error: nil,
       applied_at: nil,
       published_status: nil
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    interfaces = interfaces()
    state = %{state | interfaces: interfaces}
    {:reply, build_status(state), state}
  end

  def handle_call(:reapply, _from, state) do
    interfaces = interfaces()
    {result, state} = apply_and_record(%{state | interfaces: interfaces})
    {:reply, result, state}
  end

  def handle_call(:cycle_uplink, _from, state) do
    interfaces = interfaces()
    state = %{state | interfaces: interfaces}

    case cycle_uplink(state.settings, interfaces) do
      :ok ->
        {result, state} = apply_and_record(state)
        {:reply, result, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info(:apply_settings, state) do
    {_result, state} = apply_and_record(state)
    {:noreply, state}
  end

  def handle_info(:refresh_interfaces, state) do
    interfaces = interfaces()
    signature = interface_signature(interfaces)
    state = %{state | interfaces: interfaces}

    state =
      if signature == state.interface_signature and is_nil(state.last_error) do
        publish_observations(state)
      else
        {_result, state} =
          apply_and_record(%{state | interface_signature: signature})

        state
      end

    schedule_refresh()
    {:noreply, state}
  end

  def handle_info(%ConfigurationChanged{}, state) do
    settings = PlcRemote.Configuration.current()

    if network_settings(state.settings) == network_settings(settings) do
      {:noreply, publish_observations(%{state | settings: settings})}
    else
      interfaces = interfaces()

      {_result, state} =
        state
        |> Map.put(:settings, settings)
        |> Map.put(:interfaces, interfaces)
        |> Map.put(:interface_signature, interface_signature(interfaces))
        |> apply_and_record()

      {:noreply, state}
    end
  end

  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, _state) do
    Enum.each(@owned_alarms, &Alarm.clear/1)
    :ok
  end

  defp apply_and_record(state) do
    plan = Plan.build(state.settings, state.interfaces)
    result = Actions.apply(plan)
    state = record_result(state, result)
    {result, state}
  end

  defp cycle_uplink(settings, interfaces) do
    if PlcRemote.Health.Reporter.service_access() == :active do
      {:error, :service_mode_active}
    else
      settings
      |> PlcRemote.Network.role_ifnames(interfaces)
      |> Map.fetch!(:internet_uplink)
      |> cycle_uplink_interface()
    end
  end

  defp cycle_uplink_interface(nil), do: {:error, :internet_uplink_unassigned}

  defp cycle_uplink_interface(ifname) do
    with :ok <- Actions.disable(ifname) do
      Process.sleep(Application.get_env(:plc_remote, :uplink_cycle_delay_ms, 2_000))
      :ok
    end
  end

  defp record_result(state, :ok) do
    state
    |> Map.put(:last_error, nil)
    |> Map.put(:applied_at, DateTime.utc_now())
    |> publish_observations()
  end

  defp record_result(state, {:error, reason}) do
    error = %PlcRemote.Error{subsystem: :network, operation: :apply_plan, reason: reason}
    Logger.error("Failed to apply gateway network settings: #{inspect(reason)}")

    state
    |> Map.put(:last_error, error)
    |> Map.put(:applied_at, DateTime.utc_now())
    |> publish_observations()
  end

  defp publish_observations(state) do
    status = build_status(state)

    Alarm.report(
      NetworkConfigurationInvalid,
      not is_nil(status.last_error),
      status.last_error
    )

    Alarm.report(
      InternetUnavailable,
      internet_unavailable?(state.settings, status),
      %{connection: status.connection, interface: status.roles.internet_uplink}
    )

    Alarm.report(
      PlcInterfaceUnavailable,
      plc_interface_unavailable?(state.settings, status),
      %{interface: status.roles.machine_lan, network_error: status.last_error}
    )

    changed? = observation_changed?(state.published_status, status)
    if changed?, do: PlcRemote.Events.publish(%NetworkChanged{status: status})
    %{state | published_status: status}
  end

  defp build_status(state) do
    %Status{
      applied: not is_nil(state.applied_at) and is_nil(state.last_error),
      applied_at: state.applied_at,
      connection: adapter().connection_status(),
      interfaces: state.interfaces,
      last_error: state.last_error,
      roles: PlcRemote.Network.role_ifnames(state.settings, state.interfaces),
      uplink_mode: state.settings.uplink.mode
    }
  end

  defp observation_changed?(nil, _status), do: true

  defp observation_changed?(previous, current) do
    Map.take(previous, [:applied, :connection, :interfaces, :last_error, :roles, :uplink_mode]) !=
      Map.take(current, [:applied, :connection, :interfaces, :last_error, :roles, :uplink_mode])
  end

  defp internet_unavailable?(%{uplink: %{mode: :ethernet}}, status) do
    not is_nil(status.last_error) or is_nil(status.roles.internet_uplink) or
      status.connection != :internet
  end

  defp internet_unavailable?(_settings, _status), do: false

  defp plc_interface_unavailable?(%{machine: %{enabled: true}}, status) do
    not is_nil(status.last_error) or is_nil(status.roles.machine_lan)
  end

  defp plc_interface_unavailable?(_settings, _status), do: false

  defp network_settings(settings), do: {settings.machine, settings.uplink}

  defp interface_signature(interfaces) do
    Enum.map(interfaces, &{&1.ifname, &1.hw_path, &1.kind})
  end

  defp interfaces, do: adapter().interfaces()
  defp adapter, do: Application.fetch_env!(:plc_remote, :network_adapter)

  defp schedule_refresh do
    Process.send_after(self(), :refresh_interfaces, @refresh_interval_ms)
  end
end
