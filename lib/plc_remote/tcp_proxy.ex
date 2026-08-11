defmodule PlcRemote.TcpProxy do
  @moduledoc false

  require Logger

  @spec relay(term(), String.t(), :inet.port_number(), module()) :: :ok
  def relay(stream, address, port, tailscale_adapter) do
    options = [:binary, packet: :raw, active: false, nodelay: true, keepalive: true]

    case :gen_tcp.connect(String.to_charlist(address), port, options, 10_000) do
      {:ok, socket} ->
        relay_connected(stream, socket, tailscale_adapter)

      {:error, reason} ->
        Logger.warning("PLC proxy could not connect to #{address}:#{port}: #{inspect(reason)}")
        :ok
    end
  end

  defp relay_connected(stream, socket, tailscale_adapter) do
    parent = self()

    tail_reader =
      spawn(fn -> tail_to_tcp(stream, socket, parent, tailscale_adapter) end)

    try do
      tcp_to_tail(socket, stream, tail_reader, tailscale_adapter)
    after
      Process.exit(tail_reader, :shutdown)
      :gen_tcp.close(socket)
    end
  end

  defp tail_to_tcp(stream, socket, parent, tailscale_adapter) do
    result = tail_to_tcp_loop(stream, socket, tailscale_adapter)
    send(parent, {:tail_reader_finished, self(), result})
  end

  defp tail_to_tcp_loop(stream, socket, tailscale_adapter) do
    case tailscale_adapter.recv(stream) do
      {:ok, data} when byte_size(data) > 0 ->
        case :gen_tcp.send(socket, data) do
          :ok -> tail_to_tcp_loop(stream, socket, tailscale_adapter)
          {:error, reason} -> {:error, reason}
        end

      {:ok, <<>>} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tcp_to_tail(socket, stream, tail_reader, tailscale_adapter) do
    receive do
      {:tail_reader_finished, ^tail_reader, _result} ->
        :ok
    after
      0 ->
        case :gen_tcp.recv(socket, 0, 1_000) do
          {:ok, data} ->
            case tailscale_adapter.send_all(stream, data) do
              :ok -> tcp_to_tail(socket, stream, tail_reader, tailscale_adapter)
              {:error, _reason} -> :ok
            end

          {:error, :timeout} ->
            tcp_to_tail(socket, stream, tail_reader, tailscale_adapter)

          {:error, _reason} ->
            :ok
        end
    end
  end
end
