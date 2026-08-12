defmodule PlcRemote.Tailscale.State do
  @moduledoc false

  @enforce_keys [:adapter, :runtime, :settings, :network]
  defstruct adapter: nil,
            runtime: nil,
            settings: nil,
            network: nil,
            device: nil,
            listener: nil,
            tailnet_ipv4: nil,
            proxy_ifname: nil,
            connect_task: nil,
            listener_task: nil,
            pending_auth_key: nil,
            connected_since: nil,
            failure_count: 0,
            retry_at: nil,
            last_error: nil,
            published_status: nil

  @type t :: %__MODULE__{
          adapter: module(),
          runtime: pid(),
          settings: PlcRemote.Settings.t(),
          network: PlcRemote.Network.Status.t(),
          device: term() | nil,
          listener: term() | nil,
          tailnet_ipv4: String.t() | nil,
          proxy_ifname: String.t() | nil,
          connect_task: pid() | nil,
          listener_task: pid() | nil,
          pending_auth_key: String.t() | nil,
          connected_since: integer() | nil,
          failure_count: non_neg_integer(),
          retry_at: integer() | nil,
          last_error: PlcRemote.Error.t() | nil,
          published_status: PlcRemote.Tailscale.Status.t() | nil
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(state, opts) do
      safe = %{
        connected_since: state.connected_since,
        failure_count: state.failure_count,
        last_error: state.last_error,
        proxy_ifname: state.proxy_ifname,
        retry_at: state.retry_at,
        tailnet_ipv4: state.tailnet_ipv4
      }

      concat(["#PlcRemote.Tailscale.State<", to_doc(safe, opts), ">"])
    end
  end
end
