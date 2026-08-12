defmodule PlcRemote.Service.WebSupervisor do
  @moduledoc false

  use DynamicSupervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_server(:inet.ip_address() | :loopback, :inet.port_number()) ::
          {:ok, pid()} | {:error, term()}
  def start_server(ip, port) do
    spec =
      Bandit.child_spec(
        plug: PlcRemoteWeb.Endpoint,
        ip: ip,
        port: port,
        startup_log: false,
        http_options: [compress: true],
        http_1_options: [max_header_length: 8_192, max_request_line_length: 4_096],
        http_2_options: [enabled: false],
        websocket_options: [enabled: true, max_frame_size: 64_000]
      )

    spec = Supervisor.child_spec(spec, restart: :temporary)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @spec stop_server(pid()) :: :ok | {:error, :not_found}
  def stop_server(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
