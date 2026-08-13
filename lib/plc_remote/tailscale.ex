defmodule PlcRemote.Tailscale do
  @moduledoc "Public API for the embedded userspace Tailscale lifecycle."

  alias PlcRemote.Tailscale.{Enrollment, Runtime, Status}

  @spec status() :: Status.t()
  defdelegate status(), to: Runtime

  @spec reconnect() :: :ok
  defdelegate reconnect(), to: Runtime

  @spec enroll(Enrollment.t(), map()) :: {:ok, term(), String.t()} | {:error, term()}
  defdelegate enroll(enrollment, candidate_settings), to: Runtime

  @spec commit_enrollment(term()) :: {:ok, term()} | {:error, term()}
  defdelegate commit_enrollment(candidate), to: Runtime

  @spec finalize_enrollment(term()) :: :ok | {:error, term()}
  defdelegate finalize_enrollment(rollback), to: Runtime

  @spec rollback_enrollment(term()) :: :ok | {:error, term()}
  defdelegate rollback_enrollment(rollback), to: Runtime

  @spec discard_enrollment(term()) :: :ok
  defdelegate discard_enrollment(candidate), to: Runtime
end
