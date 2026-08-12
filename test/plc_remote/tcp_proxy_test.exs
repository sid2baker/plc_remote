defmodule PlcRemote.TcpProxyTest do
  use ExUnit.Case, async: true

  alias PlcRemote.TcpProxy

  defmodule TailscaleAdapter do
    @behaviour PlcRemote.Adapters.Tailscale

    @impl true
    def connect(_settings, _auth_key), do: {:error, :unused}

    @impl true
    def accept(_listener), do: {:error, :unused}

    @impl true
    def remote_address(_stream), do: {{100, 64, 0, 1}, 12_345}

    @impl true
    def recv(%{queue: queue}) do
      Agent.get_and_update(queue, fn
        [data | rest] ->
          {{:ok, data}, rest}

        [] ->
          Process.sleep(250)
          {{:error, :closed}, []}
      end)
    end

    @impl true
    def send_all(%{owner: owner}, data) do
      send(owner, {:tailscale_sent, data})
      :ok
    end
  end

  test "relays bytes in both directions through the fixed PLC endpoint" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    {:ok, queue} = Agent.start_link(fn -> ["from-tailnet"] end)
    stream = %{owner: self(), queue: queue}
    test_process = self()

    plc =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, payload} = :gen_tcp.recv(socket, 0, 2_000)
        send(test_process, {:plc_received, payload})
        :ok = :gen_tcp.send(socket, "from-plc")
        :gen_tcp.close(socket)
      end)

    proxy =
      spawn_link(fn ->
        TcpProxy.relay(stream, "127.0.0.1", port, "lo", TailscaleAdapter)
      end)

    assert_receive {:plc_received, "from-tailnet"}, 2_000
    assert_receive {:tailscale_sent, "from-plc"}, 2_000

    assert eventually_stops?(proxy)
    assert eventually_stops?(plc)
    :gen_tcp.close(listener)
  end

  defp eventually_stops?(pid, attempts \\ 20)
  defp eventually_stops?(_pid, 0), do: false

  defp eventually_stops?(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(25)
      eventually_stops?(pid, attempts - 1)
    else
      true
    end
  end
end
