defmodule PlcRemote.Service.WebRuntimeSupervisor do
  @moduledoc """
  Starts Phoenix's PubSub and endpoint runtime without opening a listener.

  The local service boundary starts Bandit only after the AP address exists.
  Delaying endpoint initialization until Configuration is available also gives
  every unit a unique signing secret without embedding one in public firmware.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    install_endpoint_secret()

    children = [PlcRemoteWeb.Endpoint]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp install_endpoint_secret do
    endpoint = PlcRemoteWeb.Endpoint
    current = Application.get_env(:plc_remote, endpoint, [])
    web_secret = PlcRemote.Configuration.current().service.web_secret

    secret_key_base =
      :crypto.hash(:sha512, "plc-remote-liveview:" <> web_secret)
      |> Base.encode64()

    Application.put_env(
      :plc_remote,
      endpoint,
      Keyword.put(current, :secret_key_base, secret_key_base),
      persistent: true
    )
  end
end
