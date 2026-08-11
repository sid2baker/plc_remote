defmodule PlcRemote.NetworkManager do
  @moduledoc """
  Applies persisted network intent to currently detected hardware.

  Every Ethernet update is two-phase: disable all detected ports first, then
  resolve stable hardware paths and enable only the selected machine and uplink
  roles. Interface identity is refreshed periodically so late USB discovery or
  kernel renaming is handled without opening the wrong network.
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

  @spec restore_wifi() :: :ok
  def restore_wifi do
    GenServer.cast(__MODULE__, :restore_wifi)
  end

  @doc "Reapplies the complete disable-first network plan."
  @spec reapply() :: :ok | {:error, term()}
  def reapply, do: GenServer.call(__MODULE__, :reapply, 60_000)

  @doc "Power-cycles configured Internet uplinks and reapplies their settings."
  @spec cycle_uplinks() :: :ok | {:error, term()}
  def cycle_uplinks, do: GenServer.call(__MODULE__, :cycle_uplinks, 60_000)

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
      roles: Network.role_ifnames(state.settings, interfaces)
    }

    {:reply, status, %{state | interfaces: interfaces}}
  end

  def handle_call(:reapply, _from, state) do
    interfaces = interfaces()
    result = apply_settings(state.settings, interfaces)
    state = %{state | interfaces: interfaces} |> record_result(result)
    {:reply, result, state}
  end

  def handle_call(:cycle_uplinks, _from, state) do
    interfaces = interfaces()
    result = cycle_uplinks(state.settings, interfaces)
    state = %{state | interfaces: interfaces} |> record_result(result)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast(:restore_wifi, state) do
    case apply_wifi(state.settings) do
      :ok -> {:noreply, state}
      {:error, _reason} = error -> {:noreply, record_result(state, error)}
    end
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
         {:ok, configurations} <- Network.ethernet_configurations(settings, interfaces),
         :ok <- configure_many(configurations) do
      maybe_configure_wifi(settings)
    end
  end

  defp cycle_uplinks(settings, interfaces) do
    if service_mode_active?() do
      {:error, :service_mode_active}
    else
      roles = Network.role_ifnames(settings, interfaces)

      with :ok <- disable_wired_uplink(roles.wired_uplink),
           :ok <- configure(Network.interface(:wifi_uplink), %{type: VintageNetWiFi}) do
        Process.sleep(Application.get_env(:plc_remote, :uplink_cycle_delay_ms, 2_000))
        apply_settings(settings, interfaces)
      end
    end
  end

  defp disable_wired_uplink(nil), do: :ok

  defp disable_wired_uplink(ifname) do
    configure(ifname, Network.disabled_ethernet_config())
  end

  defp maybe_configure_wifi(settings) do
    if service_mode_active?(), do: :ok, else: apply_wifi(settings)
  end

  defp apply_wifi(%{uplink: %{mode: mode}}) when mode in [:disabled, :ethernet] do
    configure(Network.interface(:wifi_uplink), %{type: VintageNetWiFi})
  end

  defp apply_wifi(%{uplink: uplink}) do
    configure(
      Network.interface(:wifi_uplink),
      Network.wifi_uplink_config(uplink.wifi, uplink.regulatory_domain)
    )
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
    %{state | last_error: nil, applied_at: DateTime.utc_now()}
  end

  defp record_result(state, {:error, reason}) do
    Logger.error("Failed to apply gateway network settings: #{inspect(reason)}")
    %{state | last_error: inspect(reason), applied_at: DateTime.utc_now()}
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

  defp interface_signature(interfaces) do
    Enum.map(interfaces, &{&1.ifname, &1.hw_path, &1.kind})
  end

  defp interfaces do
    adapter().interfaces()
  end

  defp configure(ifname, config) do
    adapter().configure(ifname, config, persist: false)
  end

  defp adapter do
    Application.fetch_env!(:plc_remote, :network_adapter)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_interfaces, @refresh_interval_ms)
  end
end
