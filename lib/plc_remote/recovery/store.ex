defmodule PlcRemote.Recovery.Store do
  @moduledoc """
  Persists only the recovery reboot budget.

  The file is deliberately independent from user settings so a failed recovery
  write cannot corrupt commissioning or network configuration.
  """

  @default %{consecutive_reboots: 0}

  @spec load(nil | Path.t()) :: map()
  def load(nil), do: @default

  def load(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"consecutive_reboots" => count}} when is_integer(count) and count >= 0 <-
           Jason.decode(contents) do
      %{consecutive_reboots: count}
    else
      _error -> @default
    end
  end

  @spec save(nil | Path.t(), map()) :: :ok | {:error, term()}
  def save(nil, _state), do: :ok

  def save(path, state) do
    directory = Path.dirname(path)
    temporary_path = path <> ".tmp"
    encoded = Jason.encode!(%{consecutive_reboots: state.consecutive_reboots})

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(temporary_path, encoded, [:binary, :sync]),
         :ok <- File.chmod(temporary_path, 0o600) do
      File.rename(temporary_path, path)
    end
  end
end
