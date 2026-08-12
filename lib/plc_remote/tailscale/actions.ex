defmodule PlcRemote.Tailscale.Actions do
  @moduledoc "Effect boundary for native Tailscale connection and fixed PLC sessions."

  require Logger

  alias PlcRemote.Tailscale.State

  @spec connect(State.t()) :: pid()
  def connect(%State{} = state) do
    auth_key = state.pending_auth_key
    settings = state.settings
    machine_ifname = machine_ifname(settings, state.network)
    runtime = state.runtime
    adapter = state.adapter

    {:ok, pid} =
      Task.Supervisor.start_child(PlcRemote.Tailscale.ConnectionSupervisor, fn ->
        result = adapter.connect(settings, auth_key, listener?: is_binary(machine_ifname))
        send(runtime, {:tailscale_connect_result, self(), result})
      end)

    pid
  end

  @spec start_listener(State.t(), term(), String.t()) :: pid()
  def start_listener(%State{} = state, listener, machine_ifname) do
    settings = state.settings
    runtime = state.runtime
    adapter = state.adapter

    {:ok, pid} =
      Task.Supervisor.start_child(PlcRemote.Tailscale.ConnectionSupervisor, fn ->
        result =
          accept_loop(
            adapter,
            listener,
            settings.machine.plc_address,
            settings.tailscale.destination_port,
            machine_ifname
          )

        send(runtime, {:tailscale_listener_result, self(), result})
      end)

    pid
  end

  @spec stop(State.t()) :: State.t()
  def stop(%State{} = state) do
    terminate_task(state.connect_task)
    terminate_task(state.listener_task)
    terminate_sessions()

    %{
      state
      | device: nil,
        listener: nil,
        tailnet_ipv4: nil,
        proxy_ifname: nil,
        connect_task: nil,
        listener_task: nil,
        connected_since: nil,
        retry_at: nil
    }
  end

  @spec active_session_count() :: non_neg_integer()
  def active_session_count do
    PlcRemote.Tailscale.SessionSupervisor
    |> Task.Supervisor.children()
    |> length()
  catch
    :exit, _reason -> 0
  end

  defp accept_loop(adapter, listener, address, port, machine_ifname) do
    case adapter.accept(listener) do
      {:ok, stream} ->
        Logger.info(
          "Accepted PLC proxy connection from #{format_remote(adapter.remote_address(stream))}"
        )

        {:ok, _pid} =
          Task.Supervisor.start_child(PlcRemote.Tailscale.SessionSupervisor, fn ->
            PlcRemote.Proxy.TcpProxy.relay(stream, address, port, machine_ifname, adapter)
          end)

        accept_loop(adapter, listener, address, port, machine_ifname)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {:accept_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:accept_stopped, kind, reason}}
  end

  defp terminate_sessions do
    PlcRemote.Tailscale.SessionSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(&Task.Supervisor.terminate_child(PlcRemote.Tailscale.SessionSupervisor, &1))
  catch
    :exit, _reason -> :ok
  end

  defp terminate_task(nil), do: :ok

  defp terminate_task(pid) when is_pid(pid) do
    Task.Supervisor.terminate_child(PlcRemote.Tailscale.ConnectionSupervisor, pid)
  catch
    :exit, _reason -> :ok
  end

  defp machine_ifname(settings, network) do
    PlcRemote.Proxy.Policy.machine_ifname(settings, network)
  end

  defp format_remote({address, port}), do: "#{format_ip(address)}:#{port}"
  defp format_remote(other), do: inspect(other)
  defp format_ip(address), do: address |> :inet.ntoa() |> to_string()
end
