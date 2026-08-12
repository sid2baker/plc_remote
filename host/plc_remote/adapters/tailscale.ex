defmodule PlcRemote.Adapters.Host.Tailscale do
  @moduledoc false

  @behaviour PlcRemote.Adapters.Tailscale

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
