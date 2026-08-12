defmodule PlcRemote.Service.Verification do
  @moduledoc "Pure final commissioning verification over the Health read model."

  alias PlcRemote.Health.Snapshot

  @type state :: :idle | :starting | :running | :passed | :failed
  @type t :: %__MODULE__{state: state(), checks: map(), error: term() | nil}

  defstruct state: :idle,
            checks: %{internet: false, tailscale: false},
            error: nil

  @spec evaluate(Snapshot.t(), PlcRemote.Settings.t()) ::
          :ok | {:wait, map()} | {:error, term()}
  def evaluate(%Snapshot{} = health, settings) do
    checks = %{
      internet: health.internet == :available,
      tailscale: settings.tailscale.enabled and health.tailscale == :connected
    }

    if Enum.all?(checks, fn {_check, passed?} -> passed? end) do
      :ok
    else
      {:wait, checks}
    end
  end

  @spec starting() :: t()
  def starting, do: %__MODULE__{state: :starting}

  @spec running(map()) :: t()
  def running(checks), do: %__MODULE__{state: :running, checks: checks}

  @spec passed(map()) :: t()
  def passed(checks), do: %__MODULE__{state: :passed, checks: checks}

  @spec failed(map(), term()) :: t()
  def failed(checks, reason), do: %__MODULE__{state: :failed, checks: checks, error: reason}
end
