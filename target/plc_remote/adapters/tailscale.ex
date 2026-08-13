defmodule PlcRemote.Adapters.Target.Tailscale do
  @moduledoc false

  @behaviour PlcRemote.Adapters.Tailscale

  @impl true
  def validate_enrollment(settings, auth_key) do
    key_file = Application.fetch_env!(:plc_remote, :tailscale_key_file)
    candidate = key_file <> ".candidate"
    _result = File.rm(candidate)

    case connect_with_key_file(candidate, settings, auth_key, []) do
      {:ok, device, nil, ipv4} ->
        if valid_node?(device) do
          {:ok, %{candidate: candidate, key_file: key_file}, ipv4}
        else
          _result = File.rm(candidate)
          {:error, :tailnet_identity_unavailable}
        end

      {:ok, _device, _listener, _ipv4} ->
        _result = File.rm(candidate)
        {:error, :unexpected_candidate_listener}

      {:error, _reason} = error ->
        _result = File.rm(candidate)
        error
    end
  end

  @impl true
  def commit_enrollment(%{candidate: candidate, key_file: key_file}) do
    backup = key_file <> ".previous"
    _result = File.rm(backup)

    with :ok <- backup_identity(key_file, backup),
         :ok <- promote_candidate(candidate, key_file) do
      {:ok, %{backup: backup, key_file: key_file}}
    else
      {:error, _reason} = error ->
        _result = restore_identity(key_file, backup)
        error
    end
  end

  @impl true
  def finalize_enrollment(%{backup: backup}) do
    case File.rm(backup) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def rollback_enrollment(%{backup: backup, key_file: key_file}) do
    restore_identity(key_file, backup)
  end

  @impl true
  def discard_enrollment(%{candidate: candidate}) do
    File.rm(candidate)
    :ok
  end

  @impl true
  def connect(settings, auth_key, opts) do
    key_file = Application.fetch_env!(:plc_remote, :tailscale_key_file)
    connect_with_key_file(key_file, settings, auth_key, opts)
  end

  defp connect_with_key_file(key_file, settings, auth_key, opts) do
    # vm.args sets this before the NIF loads. Repeat it for direct adapter use in tests and IEx.
    System.put_env("TS_RS_EXPERIMENT", "this_is_unstable_software")
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

  defp valid_node?(device) do
    case Tailscale.self_node(device) do
      {:ok, %{stable_id: stable_id}} when is_binary(stable_id) and stable_id != "" -> true
      _other -> false
    end
  end

  defp backup_identity(key_file, backup) do
    case File.rename(key_file, backup) do
      :ok -> protect_existing_key_file(backup)
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp promote_candidate(candidate, key_file) do
    with :ok <- protect_existing_key_file(candidate),
         :ok <- File.rename(candidate, key_file),
         :ok <- protect_existing_key_file(key_file) do
      :ok
    end
  end

  defp restore_identity(key_file, backup) do
    _result = File.rm(key_file)

    case File.rename(backup, key_file) do
      :ok -> protect_existing_key_file(key_file)
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

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
