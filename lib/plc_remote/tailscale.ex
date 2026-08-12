defmodule PlcRemote.Tailscale do
  @moduledoc "Public API for the embedded userspace Tailscale lifecycle."

  alias PlcRemote.Tailscale.{Enrollment, Runtime, Status}

  @spec status() :: Status.t()
  defdelegate status(), to: Runtime

  @spec reconnect() :: :ok
  defdelegate reconnect(), to: Runtime

  @spec enroll(Enrollment.t()) :: :ok
  defdelegate enroll(enrollment), to: Runtime
end
