defmodule PlcRemote.Test.QEMU do
  @moduledoc false

  @marker "PLC_REMOTE_CI:"
  @prompt ~r/iex\(\d+\)>/

  def console(socket_path, log_path, commands, opts \\ []) do
    boot_timeout = Keyword.get(opts, :boot_timeout, 180_000)
    command_timeout = Keyword.get(opts, :command_timeout, 60_000)
    File.mkdir_p!(Path.dirname(log_path))

    {:ok, socket} = connect(socket_path, boot_timeout)
    {:ok, log} = File.open(log_path, [:append, :binary])

    try do
      :ok = :gen_tcp.send(socket, "\n")
      {_output, buffer} = read_until(socket, @prompt, boot_timeout, log, "\n")

      Enum.map_reduce(commands, buffer, fn command, buffered ->
        :ok = :gen_tcp.send(socket, command <> "\n")
        {output, rest} = read_until(socket, @marker, command_timeout, log, nil, buffered)
        {line, rest} = read_line(socket, rest, command_timeout, log)
        result = @marker <> line_after_marker(output <> line)
        IO.puts(result)
        {result, rest}
      end)
      |> elem(0)
    after
      File.close(log)
      :gen_tcp.close(socket)
    end
  end

  def set_link(socket_path, device, up?) do
    {:ok, socket} = connect(socket_path, 10_000)
    up = if up?, do: "true", else: "false"

    try do
      {_greeting, buffer} = read_line(socket, <<>>, 10_000, nil)
      buffer = qmp(socket, ~s({"execute":"qmp_capabilities"}), buffer)

      qmp(
        socket,
        ~s({"execute":"set_link","arguments":{"name":"#{device}","up":#{up}}}),
        buffer
      )

      :ok
    after
      :gen_tcp.close(socket)
    end
  end

  defp qmp(socket, command, buffer) do
    :ok = :gen_tcp.send(socket, command <> "\n")
    qmp_reply(socket, buffer)
  end

  defp qmp_reply(socket, buffer) do
    {line, rest} = read_line(socket, buffer, 10_000, nil)

    cond do
      String.contains?(line, ~s("return")) -> rest
      String.contains?(line, ~s("error")) -> raise "QMP command failed: #{line}"
      true -> qmp_reply(socket, rest)
    end
  end

  defp connect(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_connect(String.to_charlist(path), deadline)
  end

  defp do_connect(path, deadline) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} when reason in [:enoent, :econnrefused, :timeout] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          do_connect(path, deadline)
        else
          raise "socket was not ready: #{path}"
        end

      {:error, reason} ->
        raise "could not connect to #{path}: #{inspect(reason)}"
    end
  end

  defp read_until(socket, needle, timeout, log, nudge, buffer \\ <<>>) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_read_until(socket, needle, deadline, log, nudge, buffer)
  end

  defp do_read_until(socket, needle, deadline, log, nudge, buffer) do
    case split_at(buffer, needle) do
      {:ok, matched, rest} ->
        {matched, rest}

      :nomatch ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          raise "timed out waiting for #{inspect(needle)}"
        end

        if nudge, do: :ok = :gen_tcp.send(socket, nudge)

        case :gen_tcp.recv(socket, 0, min(remaining, 500)) do
          {:ok, chunk} ->
            write_log(log, chunk)
            do_read_until(socket, needle, deadline, log, nudge, buffer <> chunk)

          {:error, :timeout} ->
            do_read_until(socket, needle, deadline, log, nudge, buffer)

          {:error, :closed} ->
            raise "QEMU console closed"

          {:error, reason} ->
            raise "QEMU console read failed: #{inspect(reason)}"
        end
    end
  end

  defp read_line(socket, buffer, timeout, log) do
    {line, rest} = read_until(socket, "\n", timeout, log, nil, buffer)
    {String.trim_trailing(line), rest}
  end

  defp split_at(buffer, needle) when is_binary(needle) do
    case :binary.match(buffer, needle) do
      {index, length} ->
        boundary = index + length

        {:ok, binary_part(buffer, 0, boundary),
         binary_part(buffer, boundary, byte_size(buffer) - boundary)}

      :nomatch ->
        :nomatch
    end
  end

  defp split_at(buffer, %Regex{} = pattern) do
    case Regex.run(pattern, buffer, return: :index) do
      [{index, length} | _] ->
        boundary = index + length

        {:ok, binary_part(buffer, 0, boundary),
         binary_part(buffer, boundary, byte_size(buffer) - boundary)}

      nil ->
        :nomatch
    end
  end

  defp line_after_marker(output) do
    output
    |> String.split(@marker)
    |> List.last()
    |> String.split("\n")
    |> hd()
  end

  defp write_log(nil, _chunk), do: :ok
  defp write_log(log, chunk), do: IO.binwrite(log, chunk)
end
