defmodule PlcRemote.Configuration do
  @moduledoc """
  Owns the validated gateway settings and persists updates atomically.
  """

  use GenServer

  require Logger

  alias PlcRemote.Events.ConfigurationChanged
  alias PlcRemote.Settings
  alias PlcRemote.Settings.Store

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current validated settings."
  @spec current() :: Settings.t()
  def current, do: GenServer.call(__MODULE__, :current)

  @doc false
  @deprecated "Use current/0"
  def get, do: current()

  @doc "Returns the monotonically increasing in-memory configuration revision."
  @spec revision() :: non_neg_integer()
  def revision, do: GenServer.call(__MODULE__, :revision)

  @doc "Validates, persists, and applies web-form settings."
  @spec update(map()) :: {:ok, Settings.t()} | {:error, Settings.errors() | term()}
  def update(params), do: GenServer.call(__MODULE__, {:update, params}, 30_000)

  @doc "Atomically enables the successfully enrolled tailnet configuration."
  @spec complete_enrollment(map()) :: {:ok, Settings.t()} | {:error, Settings.errors() | term()}
  def complete_enrollment(params),
    do: GenServer.call(__MODULE__, {:complete_enrollment, params}, 30_000)

  @doc "Restores a previously validated settings snapshot."
  @spec restore(Settings.t()) :: :ok | {:error, term()}
  def restore(settings), do: GenServer.call(__MODULE__, {:restore, settings}, 30_000)

  @doc "Returns the local service access-point credentials for manufacturing."
  @spec service_credentials() :: %{address: String.t(), psk: String.t(), ssid_prefix: String.t()}
  def service_credentials do
    settings = current()

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
      {:ok, %{path: path, settings: settings, revision: 0}}
    else
      {:error, reason} -> {:stop, {:settings_unavailable, reason}}
    end
  end

  @impl GenServer
  def handle_call(:current, _from, state), do: {:reply, state.settings, state}
  def handle_call(:revision, _from, state), do: {:reply, state.revision, state}

  def handle_call({:restore, settings}, _from, state) do
    case Store.save(state.path, settings) do
      :ok ->
        state = publish_configuration(%{state | settings: settings})
        {:reply, :ok, state}

      {:error, reason} = error ->
        Logger.error("Unable to restore the previous gateway settings: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:update, params}, _from, state) do
    persist_update(state, params, &Function.identity/1)
  end

  def handle_call({:complete_enrollment, params}, _from, state) do
    persist_update(state, params, &Map.put(&1, :commissioned, true))
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

  defp persist_update(state, params, transform) do
    with {:ok, settings} <- Settings.update(state.settings, params),
         settings <- transform.(settings),
         :ok <- Store.save(state.path, settings) do
      state = publish_configuration(%{state | settings: settings})
      {:reply, {:ok, settings}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp publish_configuration(state) do
    revision = state.revision + 1

    :ok =
      PlcRemote.Events.publish(%ConfigurationChanged{revision: revision})

    %{state | revision: revision}
  end

  defp settings_path do
    Application.get_env(:plc_remote, :settings_path)
  end

  defp default_gpio_spec do
    Application.get_env(:plc_remote, :default_service_gpio, "GPIO23")
  end
end
