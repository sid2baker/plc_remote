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

  @doc "Persists that this gateway successfully joined its tailnet."
  @spec mark_commissioned() :: :ok | {:error, term()}
  def mark_commissioned, do: GenServer.call(__MODULE__, :mark_commissioned, 30_000)

  @doc "Restores a previously validated settings snapshot."
  @spec restore(Settings.t()) :: :ok | {:error, term()}
  def restore(settings), do: GenServer.call(__MODULE__, {:restore, settings}, 30_000)

  @doc "Starts an atomic onsite settings transaction before applying candidate settings."
  @spec begin_service_transaction() :: :ok | {:error, term()}
  def begin_service_transaction,
    do: GenServer.call(__MODULE__, :begin_service_transaction, 30_000)

  @doc "Keeps candidate onsite settings after they pass final verification."
  @spec commit_service_transaction() :: :ok | {:error, term()}
  def commit_service_transaction,
    do: GenServer.call(__MODULE__, :commit_service_transaction, 30_000)

  @doc "Restores settings from before the current onsite service session."
  @spec rollback_service_transaction() :: :ok | {:error, term()}
  def rollback_service_transaction,
    do: GenServer.call(__MODULE__, :rollback_service_transaction, 30_000)

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

    rollback_path = rollback_path(path)

    with {:ok, settings, origin} <-
           load_or_recover_interrupted_transaction(path, rollback_path, defaults_opts),
         :ok <- persist_new_settings(path, settings, origin) do
      {:ok,
       %{
         path: path,
         rollback_path: rollback_path,
         service_snapshot: nil,
         settings: settings,
         revision: 0
       }}
    else
      {:error, reason} -> {:stop, {:settings_unavailable, reason}}
    end
  end

  @impl GenServer
  def handle_call(:current, _from, state), do: {:reply, state.settings, state}
  def handle_call(:revision, _from, state), do: {:reply, state.revision, state}

  def handle_call(:begin_service_transaction, _from, state) do
    case begin_transaction(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:commit_service_transaction, _from, state) do
    case Store.remove(state.rollback_path) do
      :ok -> {:reply, :ok, %{state | service_snapshot: nil}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:rollback_service_transaction, _from, %{service_snapshot: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:rollback_service_transaction, _from, state) do
    snapshot = state.service_snapshot

    with :ok <- Store.save(state.path, snapshot),
         :ok <- Store.remove(state.rollback_path) do
      state = publish_configuration(%{state | settings: snapshot, service_snapshot: nil})
      {:reply, :ok, state}
    else
      {:error, reason} = error ->
        Logger.error("Unable to roll back onsite settings: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call(:mark_commissioned, _from, %{settings: %{commissioned: true}} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:mark_commissioned, _from, state) do
    settings = Map.put(state.settings, :commissioned, true)

    case Store.save(state.path, settings) do
      :ok ->
        Logger.info("Gateway commissioning marker persisted after final verification")
        state = publish_configuration(%{state | settings: settings})
        {:reply, :ok, state}

      {:error, reason} = error ->
        Logger.error("Unable to persist commissioning state: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:restore, settings}, _from, state) do
    with :ok <- Store.save(state.path, settings),
         :ok <- Store.remove(state.rollback_path) do
      state = publish_configuration(%{state | settings: settings, service_snapshot: nil})
      {:reply, :ok, state}
    else
      {:error, reason} = error ->
        Logger.error("Unable to restore the previous gateway settings: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:update, params}, _from, state) do
    with {:ok, settings} <- Settings.update(state.settings, params),
         :ok <- Store.save(state.path, settings) do
      state = publish_configuration(%{state | settings: settings})
      {:reply, {:ok, settings}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp load_or_recover_interrupted_transaction(path, nil, defaults_opts) do
    load_or_recover(path, defaults_opts)
  end

  defp load_or_recover_interrupted_transaction(path, rollback_path, defaults_opts) do
    case Store.load(rollback_path, defaults_opts) do
      {:ok, snapshot, :existing} ->
        Logger.warning("Restoring settings from an interrupted onsite service transaction")

        with :ok <- Store.save(path, snapshot),
             :ok <- Store.remove(rollback_path) do
          {:ok, snapshot, :existing}
        end

      {:ok, _defaults, :new} ->
        load_or_recover(path, defaults_opts)

      {:error, reason} ->
        Logger.error("Onsite rollback settings are invalid: #{inspect(reason)}")

        with :ok <- Store.quarantine(rollback_path) do
          load_or_recover(path, defaults_opts)
        end
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

  defp begin_transaction(%{service_snapshot: snapshot} = state) when not is_nil(snapshot),
    do: {:ok, state}

  defp begin_transaction(state) do
    case Store.save(state.rollback_path, state.settings) do
      :ok -> {:ok, %{state | service_snapshot: state.settings}}
      {:error, _reason} = error -> error
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

  defp rollback_path(nil), do: nil
  defp rollback_path(path), do: path <> ".service-rollback"

  defp default_gpio_spec do
    Application.get_env(:plc_remote, :default_service_gpio, "GPIO23")
  end
end
