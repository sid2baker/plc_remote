defmodule PlcRemote.NetworkManager do
  @moduledoc """
  Applies the two stable Ethernet roles and keeps every other Ethernet port off.

  Every update is disable-first: all detected Ethernet interfaces are disabled,
  then only the configured Internet and PLC ports are enabled. Wi-Fi is not an
  Internet uplink and is owned exclusively by service mode.
  """

  use GenServer

  require Logger

  alias PlcRemote.{Configuration, Network}

  @refresh_interval_ms 5_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Reapplies the complete disable-first Ethernet plan."
  @spec reapply() :: :ok | {:error, term()}
  def reapply, do: GenServer.call(__MODULE__, :reapply, 60_000)

  @doc "Power-cycles the configured Internet Ethernet interface."
  @spec cycle_uplink() :: :ok | {:error, term()}
  def cycle_uplink, do: GenServer.call(__MODULE__, :cycle_uplink, 60_000)

  @impl GenServer
  def init(_opts) do
    settings = Configuration.get()
    interfaces = interfaces()
    send(self(), :apply_settings)
    schedule_refresh()

    {:ok,
     %{
       settings: settings,
       interfaces: interfaces,
       interface_signature: interface_signature(interfaces),
       last_error: nil,
       applied_at: nil
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    interfaces = interfaces()

    status = %{
      applied_at: state.applied_at,
      connection: adapter().connection_status(),
      interfaces: interfaces,
      last_error: state.last_error,
      roles: Network.role_ifnames(state.settings, interfaces),
      uplink_mode: state.settings.uplink.mode
    }

    {:reply, status, %{state | interfaces: interfaces}}
  end

  def handle_call(:reapply, _from, state) do
    interfaces = interfaces()
    result = apply_settings(state.settings, interfaces)
    state = %{state | interfaces: interfaces} |> record_result(result)
    {:reply, result, state}
  end

  def handle_call(:cycle_uplink, _from, state) do
    interfaces = interfaces()
    result = cycle_uplink(state.settings, interfaces)
    state = %{state | interfaces: interfaces}
    state = if result == :ok, do: record_result(state, result), else: state
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:apply_settings, state) do
    interfaces = interfaces()
    result = apply_settings(state.settings, interfaces)

    {:noreply,
     state
     |> Map.put(:interfaces, interfaces)
     |> Map.put(:interface_signature, interface_signature(interfaces))
     |> record_result(result)}
  end

  def handle_info(:refresh_interfaces, state) do
    interfaces = interfaces()
    signature = interface_signature(interfaces)

    state =
      if signature == state.interface_signature and is_nil(state.last_error) do
        %{state | interfaces: interfaces}
      else
        state
        |> Map.put(:interfaces, interfaces)
        |> Map.put(:interface_signature, signature)
        |> record_result(apply_settings(state.settings, interfaces))
      end

    schedule_refresh()
    {:noreply, state}
  end

  def handle_info({:settings_updated, settings, _auth_key}, state) do
    if network_settings(state.settings) == network_settings(settings) do
      {:noreply, %{state | settings: settings}}
    else
      interfaces = interfaces()
      result = apply_settings(settings, interfaces)

      {:noreply,
       state
       |> Map.put(:settings, settings)
       |> Map.put(:interfaces, interfaces)
       |> Map.put(:interface_signature, interface_signature(interfaces))
       |> record_result(result)}
    end
  end

  defp apply_settings(settings, interfaces) do
    with :ok <- disable_ethernet(Network.ethernet_baseline(interfaces)),
         {:ok, configurations} <- Network.ethernet_configurations(settings, interfaces) do
      configure_many(configurations)
    end
  end

  defp cycle_uplink(settings, interfaces) do
    if service_mode_active?() do
      {:error, :service_mode_active}
    else
      case Network.role_ifnames(settings, interfaces).internet_uplink do
        nil -> {:error, :internet_uplink_unassigned}
        ifname -> cycle_interface(ifname, settings, interfaces)
      end
    end
  end

  defp cycle_interface(ifname, settings, interfaces) do
    with :ok <- configure(ifname, Network.disabled_ethernet_config()) do
      Process.sleep(Application.get_env(:plc_remote, :uplink_cycle_delay_ms, 2_000))
      apply_settings(settings, interfaces)
    end
  end

  defp disable_ethernet(configurations) do
    Enum.reduce(configurations, :ok, fn {ifname, config}, result ->
      case configure(ifname, config) do
        :ok -> result
        {:error, _reason} = error when result == :ok -> error
        {:error, _reason} -> result
      end
    end)
  end

  defp configure_many(configurations) do
    Enum.reduce_while(configurations, :ok, fn {ifname, config}, :ok ->
      case configure(ifname, config) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp record_result(state, :ok) do
    applied_at = DateTime.utc_now()
    roles = Network.role_ifnames(state.settings, state.interfaces)

    notify_tailscale(
      PlcRemote.ProxyPolicy.machine_ifname(state.settings, %{last_error: nil, roles: roles})
    )

    %{state | last_error: nil, applied_at: applied_at}
  end

  defp record_result(state, {:error, reason}) do
    Logger.error("Failed to apply gateway network settings: #{inspect(reason)}")
    notify_tailscale(nil)
    %{state | last_error: inspect(reason), applied_at: DateTime.utc_now()}
  end

  defp notify_tailscale(machine_ifname) do
    if pid = Process.whereis(PlcRemote.TailscaleManager) do
      send(pid, {:machine_interface_changed, machine_ifname})
    end
  end

  defp service_mode_active? do
    case Process.whereis(PlcRemote.ServiceMode) do
      nil -> false
      _pid -> PlcRemote.ServiceMode.active?()
    end
  catch
    :exit, _reason -> false
  end

  defp network_settings(settings), do: {settings.machine, settings.uplink}

  defp interface_signature(interfaces),
    do: Enum.map(interfaces, &{&1.ifname, &1.hw_path, &1.kind})

  defp interfaces, do: adapter().interfaces()
  defp configure(ifname, config), do: adapter().configure(ifname, config, persist: false)
  defp adapter, do: Application.fetch_env!(:plc_remote, :network_adapter)

  defp schedule_refresh do
    Process.send_after(self(), :refresh_interfaces, @refresh_interval_ms)
  end
end
