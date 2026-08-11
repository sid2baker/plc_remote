defmodule PlcRemote.Firmware.ExpectationStore do
  @moduledoc """
  Persists evidence that the previous firmware had working remote access
  immediately before an OTA update.
  """

  @spec load(nil | Path.t()) :: boolean()
  def load(nil), do: false

  def load(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"remote_expected" => true}} <- Jason.decode(contents) do
      true
    else
      _error -> false
    end
  end

  @spec mark(nil | Path.t()) :: :ok | {:error, term()}
  def mark(nil), do: :ok

  def mark(path) do
    directory = Path.dirname(path)
    temporary_path = path <> ".tmp"
    encoded = Jason.encode!(%{remote_expected: true})

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(temporary_path, encoded, [:binary, :sync]),
         :ok <- File.chmod(temporary_path, 0o600) do
      File.rename(temporary_path, path)
    end
  end

  @spec clear(nil | Path.t()) :: :ok | {:error, term()}
  def clear(nil), do: :ok

  def clear(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
