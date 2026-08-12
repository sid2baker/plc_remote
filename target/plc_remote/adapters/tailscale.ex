defmodule PlcRemote.Adapters.Target.Tailscale do
  @moduledoc false

  @behaviour PlcRemote.Adapters.Tailscale

  @impl true
  def connect(settings, auth_key, opts) do
    # vm.args sets this before the NIF loads. Repeat it for direct adapter use in tests and IEx.
    System.put_env("TS_RS_EXPERIMENT", "this_is_unstable_software")
    key_file = Application.fetch_env!(:plc_remote, :tailscale_key_file)
    directory = Path.dirname(key_file)
    :ok = File.mkdir_p(directory)
    :ok = File.chmod(directory, 0o700)
    :ok = protect_existing_key_file(key_file)

    options =
      [hostname: settings.tailscale.hostname]
      |> maybe_add_tags(settings.tailscale.tags)
      |> maybe_add_auth_key(auth_key)

    with {:ok, device} <- Tailscale.connect(key_file, options),
         :ok <- protect_existing_key_file(key_file),
         {:ok, tailnet_ipv4} <- Tailscale.ipv4_addr(device),
         {:ok, listener} <- maybe_listen(device, settings, opts),
         :ok <- protect_existing_key_file(key_file) do
      {:ok, device, listener, tailnet_ipv4}
    end
  end

  @impl true
  def accept(listener), do: Tailscale.Tcp.Listener.accept(listener)

  @impl true
  def remote_address(stream), do: Tailscale.Tcp.Stream.remote_addr(stream)

  @impl true
  def recv(stream), do: Tailscale.Tcp.Stream.recv(stream)

  @impl true
  def send_all(stream, data), do: Tailscale.Tcp.Stream.send_all(stream, data)

  defp protect_existing_key_file(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_listen(device, settings, opts) do
    if Keyword.get(opts, :listener?, false) do
      Tailscale.Tcp.listen(device, :ip4, settings.tailscale.listen_port)
    else
      {:ok, nil}
    end
  end

  defp maybe_add_tags(options, []), do: options
  defp maybe_add_tags(options, tags), do: Keyword.put(options, :tags, tags)

  defp maybe_add_auth_key(options, nil), do: options
  defp maybe_add_auth_key(options, auth_key), do: Keyword.put(options, :auth_key, auth_key)
end
