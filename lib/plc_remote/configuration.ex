defmodule PlcRemote.Configuration do
  @moduledoc """
  Owns the validated gateway settings and persists updates atomically.
  """

  use GenServer

  require Logger

  alias PlcRemote.Settings
  alias PlcRemote.Settings.Store

  @subscribers [
    PlcRemote.NetworkManager,
    PlcRemote.TailscaleManager,
    PlcRemote.ServiceMode,
    PlcRemote.RecoveryManager
  ]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current validated settings."
  @spec get() :: Settings.t()
  def get, do: GenServer.call(__MODULE__, :get)

  @doc "Validates, persists, and applies web-form settings."
  @spec update(map()) :: {:ok, Settings.t()} | {:error, Settings.errors() | term()}
  def update(params), do: GenServer.call(__MODULE__, {:update, params}, 30_000)

  @doc "Persists that this gateway successfully joined its tailnet."
  @spec mark_commissioned() :: :ok | {:error, term()}
  def mark_commissioned, do: GenServer.call(__MODULE__, :mark_commissioned, 30_000)

  @doc "Returns the local service access-point credentials for manufacturing."
  @spec service_credentials() :: %{address: String.t(), psk: String.t(), ssid_prefix: String.t()}
  def service_credentials do
    settings = get()

    %{
      address: settings.service.address,
      psk: settings.service.psk,
      ssid_prefix: settings.service.ssid_prefix
    }
  end

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :path, settings_path())
    defaults_opts = [gpio_spec: default_gpio_spec()]

    with {:ok, settings, origin} <- load_or_recover(path, defaults_opts),
         :ok <- persist_new_settings(path, settings, origin) do
      {:ok, %{path: path, settings: settings}}
    else
      {:error, reason} -> {:stop, {:settings_unavailable, reason}}
    end
  end

  @impl GenServer
  def handle_call(:get, _from, state), do: {:reply, state.settings, state}

  def handle_call(:mark_commissioned, _from, %{settings: %{commissioned: true}} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:mark_commissioned, _from, state) do
    settings = Map.put(state.settings, :commissioned, true)

    case Store.save(state.path, settings) do
      :ok ->
        Logger.info("Gateway commissioning completed after successful tailnet enrollment")
        notify_subscribers(settings, nil)
        {:reply, :ok, %{state | settings: settings}}

      {:error, reason} = error ->
        Logger.error("Unable to persist commissioning state: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:update, params}, _from, state) do
    with {:ok, settings, auth_key} <- Settings.update(state.settings, params),
         :ok <- Store.save(state.path, settings) do
      notify_subscribers(settings, auth_key)
      {:reply, {:ok, settings}, %{state | settings: settings}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp load_or_recover(path, defaults_opts) do
    case Store.load(path, defaults_opts) do
      {:ok, settings, origin} ->
        {:ok, settings, origin}

      {:error, {:invalid_settings, reason}} ->
        Logger.error("Gateway settings are invalid; quarantining them: #{inspect(reason)}")

        with :ok <- Store.quarantine(path) do
          {:ok, Settings.defaults(defaults_opts), :new}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_new_settings(_path, _settings, :existing), do: :ok
  defp persist_new_settings(path, settings, :new), do: Store.save(path, settings)

  defp notify_subscribers(settings, auth_key) do
    Enum.each(@subscribers, fn name ->
      if pid = Process.whereis(name) do
        send(pid, {:settings_updated, settings, auth_key})
      end
    end)
  end

  defp settings_path do
    Application.get_env(:plc_remote, :settings_path)
  end

  defp default_gpio_spec do
    Application.get_env(:plc_remote, :default_service_gpio, "GPIO17")
  end
end
