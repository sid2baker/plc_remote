defmodule PlcRemoteWeb.Page do
  @moduledoc false

  require EEx

  @template Application.app_dir(:plc_remote, "priv/templates/settings.html.eex")

  EEx.function_from_file(:def, :render, @template, [:assigns], trim: true)

  defp h(nil), do: ""

  defp h(value) do
    value
    |> to_string()
    |> Plug.HTML.html_escape()
  end

  defp checked(true), do: "checked"
  defp checked(_value), do: ""

  defp selected(value, value), do: "selected"
  defp selected(_current, _option), do: ""

  defp ethernet_interfaces(interfaces) do
    Enum.filter(interfaces, &(&1.kind == :ethernet))
  end

  defp interface_options(interfaces, current_path) do
    options =
      interfaces
      |> ethernet_interfaces()
      |> Enum.map(&%{path: &1.hw_path, label: interface_label(&1)})

    if current_path in [nil, ""] or Enum.any?(options, &(&1.path == current_path)) do
      options
    else
      [%{path: current_path, label: "Configured port (not currently detected)"} | options]
    end
  end

  defp interface_label(interface) do
    driver = interface.driver || "unknown driver"
    speed = if interface.speed_mbps, do: "#{interface.speed_mbps} Mb/s", else: "speed unknown"

    link =
      case interface.lower_up do
        true -> "link up"
        false -> "link down"
        nil -> "link unknown"
      end

    connection = connection_label(interface.connection)
    "#{interface.ifname} · #{driver} · #{speed} · #{link} · #{connection}"
  end

  defp remaining_label(%{mode: :automatic}), do: "Until tailnet enrollment"
  defp remaining_label(%{expires_in_seconds: nil}), do: "Not active"
  defp remaining_label(service), do: "#{service.expires_in_seconds} seconds"

  defp error(errors, field) do
    case Map.get(errors, field) do
      nil -> ""
      message -> ~s(<p class="field-error">#{h(message)}</p>)
    end
  end

  defp state_label(:connected), do: "Connected"
  defp state_label(:connecting), do: "Connecting"
  defp state_label(:disabled), do: "Disabled"
  defp state_label(:error), do: "Error"
  defp state_label(:unavailable), do: "Unavailable on host"
  defp state_label(other), do: other |> to_string() |> String.capitalize()

  defp connection_label(:internet), do: "Internet"
  defp connection_label(:lan), do: "LAN only"
  defp connection_label(:disconnected), do: "Offline"
  defp connection_label(_status), do: "Unknown"

  defp state_class(:connected), do: "ok"
  defp state_class(:connecting), do: "pending"
  defp state_class(:error), do: "error"
  defp state_class(:internet), do: "ok"
  defp state_class(:lan), do: "pending"
  defp state_class(:disconnected), do: "error"
  defp state_class(_state), do: "muted"
end
