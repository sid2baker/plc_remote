case System.argv() do
  [host, port] ->
    payload = "plc-remote-tailnet"

    with {:ok, socket} <-
           :gen_tcp.connect(
             String.to_charlist(host),
             String.to_integer(port),
             [:binary, active: false],
             30_000
           ),
         :ok <- :gen_tcp.send(socket, payload),
         {:ok, ^payload} <- :gen_tcp.recv(socket, byte_size(payload), 30_000) do
      :gen_tcp.close(socket)
      IO.puts("Live tailnet PLC proxy echo passed")
    else
      error -> raise "PLC proxy echo failed: #{inspect(error)}"
    end

  _other ->
    IO.puts(:stderr, "usage: tcp_echo_client.exs HOST PORT")
    System.halt(2)
end
