defmodule PlcRemote.Adapters.Host.Tailscale do
  @moduledoc false

  @behaviour PlcRemote.Adapters.Tailscale

  @impl true
  def validate_enrollment(_settings, _auth_key) do
    case Application.get_env(:plc_remote, :host_tailscale_enrollment_result, {
           :error,
           :not_available_on_host
         }) do
      {:ok, ipv4} -> {:ok, :host_candidate, ipv4}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def commit_enrollment(:host_candidate), do: {:ok, :host_rollback}

  @impl true
  def finalize_enrollment(:host_rollback), do: :ok

  @impl true
  def rollback_enrollment(:host_rollback), do: :ok

  @impl true
  def discard_enrollment(_candidate), do: :ok

  @impl true
  def connect(_settings, _auth_key, _opts), do: {:error, :not_available_on_host}

  @impl true
  def accept(_listener), do: {:error, :not_available_on_host}

  @impl true
  def remote_address(_stream), do: :not_available_on_host

  @impl true
  def recv(_stream), do: {:error, :not_available_on_host}

  @impl true
  def send_all(_stream, _data), do: {:error, :not_available_on_host}
end
