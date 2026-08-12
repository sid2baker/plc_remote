defmodule PlcRemoteWeb.CommissioningLive do
  use PlcRemoteWeb, :live_view

  alias PlcRemote.{Configuration, Firmware, Health, Network, Recovery, Service, Tailscale}

  @refresh_interval_ms 1_000
  @steps ~w(network tailscale verify advanced)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:settings, Configuration.current())
      |> assign(:draft, %{})
      |> assign(:errors, %{})
      |> assign(:notice, nil)
      |> assign(:handoff, nil)
      |> assign(:network_saved, false)
      |> refresh_status()

    if connected?(socket) do
      Service.touch()
      send(self(), :refresh)
    end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    step = normalize_step(Map.get(params, "step"), socket.assigns.settings.commissioned)
    {:noreply, assign(socket, :step, step)}
  end

  @impl Phoenix.LiveView
  def handle_event("save-network", %{"settings" => params}, socket) do
    params = Map.put(params, "uplink_mode", "ethernet")

    save_step(socket, params, "Ethernet settings applied. Testing Internet…", nil,
      network_saved: true
    )
  end

  def handle_event("save-tailscale", %{"settings" => params}, socket) do
    save_step(socket, params, "Tailscale settings applied. Connecting…", nil, [])
  end

  def handle_event("save-advanced", %{"settings" => params}, socket) do
    save_step(socket, params, "Service and recovery settings saved.", "advanced", [])
  end

  def handle_event("finish-commissioning", _params, socket) do
    case Service.finish_commissioning() do
      {:ok, :verifying} ->
        {:noreply, assign(socket, handoff: :verification, notice: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :errors, %{"finish" => finish_error(reason)})}
    end
  end

  def handle_event("exit-service", _params, socket) do
    Task.start(fn ->
      Process.sleep(750)
      Service.deactivate()
    end)

    {:noreply, assign(socket, :handoff, :exit)}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    socket = refresh_status(socket)
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, socket}
  end

  defp save_step(socket, params, notice, next_step, extra_assigns) do
    Service.touch()
    {enrollment, params} = PlcRemote.Settings.pop_enrollment(params)

    case Configuration.update(params) do
      {:ok, settings} ->
        if enrollment, do: Tailscale.enroll(enrollment)

        socket =
          socket
          |> assign(:settings, settings)
          |> assign(:draft, %{})
          |> assign(:errors, %{})
          |> assign(:notice, notice)
          |> assign(extra_assigns)
          |> refresh_status()
          |> maybe_push_step(next_step)

        {:noreply, socket}

      {:error, errors} when is_map(errors) ->
        {:noreply, assign(socket, errors: errors, draft: public_draft(params), notice: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           errors: %{"settings" => "Settings could not be persisted: #{inspect(reason)}"},
           draft: public_draft(params),
           notice: nil
         )}
    end
  end

  defp maybe_push_step(socket, nil), do: socket
  defp maybe_push_step(socket, step), do: push_patch(socket, to: "/?step=#{step}")
  defp public_draft(params), do: Map.drop(params, ["tailscale_auth_key", "service_psk"])

  defp refresh_status(socket) do
    service = Service.status()

    socket =
      assign(socket,
        settings: Configuration.current(),
        firmware: Firmware.status(),
        health: Health.snapshot(),
        network: Network.status(),
        recovery: Recovery.status(),
        service: service,
        tailscale: Tailscale.status()
      )

    if socket.assigns.handoff == :verification and service.verification.state == :failed do
      assign(socket, :handoff, nil)
    else
      socket
    end
  end

  defp normalize_step(step, true) when step in @steps, do: step
  defp normalize_step(step, false) when step in ~w(network tailscale verify), do: step
  defp normalize_step(_step, _commissioned), do: "network"

  defp ready_to_test?(settings) do
    settings.uplink.mode == :ethernet and settings.tailscale.enabled
  end

  defp network_ready_to_continue?(_settings, network), do: network.connection == :internet

  defp tailscale_ready_to_continue?(_settings, _network, tailscale) do
    tailscale.lifecycle == :connected
  end

  defp check_state(true), do: :ok
  defp check_state(false), do: :pending

  defp tailscale_check_state(%{lifecycle: :connected}), do: :ok
  defp tailscale_check_state(%{lifecycle: :retry_wait}), do: :error
  defp tailscale_check_state(_tailscale), do: :pending

  defp finish_error(:automatic_commissioning_not_active),
    do: "Final commissioning is available only from the first-boot setup AP."

  defp finish_error(reason), do: inspect(reason)

  defp error_reason(nil), do: nil
  defp error_reason(%PlcRemote.Error{reason: reason}), do: inspect(reason)
  defp error_reason(reason), do: inspect(reason)

  defp value(draft, field, fallback), do: Map.get(draft, field, fallback)

  defp checked?(draft, field, fallback) do
    case Map.fetch(draft, field) do
      {:ok, field_value} -> field_value in [true, "true", "on", "1", 1]
      :error -> fallback
    end
  end

  defp selected?(value, option), do: to_string(value) == to_string(option)
  defp ethernet_interfaces(interfaces), do: Enum.filter(interfaces, &(&1.kind == :ethernet))

  defp effective_port_path(draft, field, configured, interfaces, role) do
    case Map.fetch(draft, field) do
      {:ok, path} -> path
      :error when configured not in [nil, ""] -> configured
      :error -> suggested_port_path(interfaces, role)
    end
  end

  defp suggested_port_path(interfaces, :uplink) do
    ethernet = ethernet_interfaces(interfaces)

    interface =
      Enum.find(ethernet, &(&1.lower_up and usb_ethernet?(&1))) ||
        Enum.find(ethernet, & &1.lower_up) ||
        Enum.find(ethernet, &usb_ethernet?/1) ||
        List.first(ethernet)

    interface_path(interface)
  end

  defp usb_ethernet?(interface) do
    interface.driver in ["r8152", "ax88179_178a"] or String.contains?(interface.hw_path, "/usb")
  end

  defp interface_path(nil), do: ""
  defp interface_path(interface), do: interface.hw_path

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
    link = if interface.lower_up, do: "link up", else: "link down"
    "#{interface.ifname} · #{driver} · #{speed} · #{link}"
  end

  defp remaining_label(%{lifecycle: lifecycle})
       when lifecycle in [:automatic, :verifying_automatic],
       do: "No timeout during setup"

  defp remaining_label(%{expires_in_seconds: nil}), do: "Not active"
  defp remaining_label(service), do: "#{service.expires_in_seconds} seconds"
end
