defmodule PlcRemote.Settings.Store do
  @moduledoc false

  alias PlcRemote.Settings

  @spec load(nil | Path.t(), keyword()) ::
          {:ok, Settings.t(), :existing | :new} | {:error, term()}
  def load(nil, opts), do: {:ok, Settings.defaults(opts), :new}

  def load(path, opts) do
    case File.read(path) do
      {:ok, contents} ->
        case Settings.decode(contents, opts) do
          {:ok, settings} -> {:ok, settings, :existing}
          {:error, reason} -> {:error, {:invalid_settings, reason}}
        end

      {:error, :enoent} ->
        {:ok, Settings.defaults(opts), :new}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec save(nil | Path.t(), Settings.t()) :: :ok | {:error, term()}
  def save(nil, _settings), do: :ok

  def save(path, settings) do
    temporary_path = path <> ".tmp"

    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, encoded} <- Settings.encode(settings),
         :ok <- File.write(temporary_path, encoded, [:binary, :sync]),
         :ok <- File.chmod(temporary_path, 0o600) do
      File.rename(temporary_path, path)
    end
  end

  @spec quarantine(nil | Path.t()) :: :ok | {:error, term()}
  def quarantine(nil), do: :ok

  def quarantine(path) do
    timestamp = System.system_time(:second)
    File.rename(path, "#{path}.invalid-#{timestamp}")
  end
end
