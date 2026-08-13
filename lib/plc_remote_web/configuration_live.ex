defmodule PlcRemoteWeb.ConfigurationLive do
  use PlcRemoteWeb, :live_view

  alias PlcRemote.{Configuration, Network, Service, Settings, Tailscale}

  @refresh_interval_ms 1_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:draft, %{})
      |> assign(:errors, %{})
      |> assign(:notice, nil)
      |> assign(:enrolling, false)
      |> assign(:enrollment_task, nil)
      |> refresh_status()

    if connected?(socket), do: send(self(), :refresh)
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("save-network", %{"settings" => params}, socket) do
    params = Map.put(params, "uplink_mode", "ethernet")
    save_settings(socket, params, "Network settings saved.")
  end

  def handle_event("save-plc", %{"settings" => params}, socket) do
    save_settings(socket, params, "PLC network settings saved.")
  end

  def handle_event("enroll-tailscale", _params, %{assigns: %{enrolling: true}} = socket),
    do: {:noreply, socket}

  def handle_event("enroll-tailscale", %{"settings" => params}, socket) do
    {enrollment_result, public_params} = Settings.pop_enrollment(params)
    public_params = Map.put(public_params, "tailscale_enabled", "true")

    with {:ok, enrollment} <- enrollment_result,
         {:ok, candidate_settings} <- Settings.update(Configuration.current(), public_params) do
      owner = self()

      {:ok, task} =
        Task.Supervisor.start_child(PlcRemote.Tailscale.ConnectionSupervisor, fn ->
          result = enroll_candidate(enrollment, candidate_settings, public_params)
          send(owner, {:enrollment_result, self(), result})
        end)

      {:noreply,
       socket
       |> assign(:enrolling, true)
       |> assign(:enrollment_task, task)
       |> assign(:draft, public_draft(public_params))
       |> assign(:errors, %{})
       |> assign(:notice, nil)}
    else
      {:error, reason} -> handle_enrollment_error(socket, public_params, reason)
    end
  end

  def handle_event("disable-tailscale", _params, socket) do
    save_settings(socket, %{"tailscale_enabled" => "false"}, "Tailscale disabled.")
  end

  @impl Phoenix.LiveView
  def handle_info(
        {:enrollment_result, task, result},
        %{assigns: %{enrollment_task: task}} = socket
      ) do
    {:noreply, finish_enrollment(socket, result)}
  end

  def handle_info({:enrollment_result, _task, _result}, socket), do: {:noreply, socket}

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, refresh_status(socket)}
  end

  defp save_settings(socket, params, notice) do
    case Configuration.update(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(:settings, settings)
         |> assign(:draft, %{})
         |> assign(:errors, %{})
         |> assign(:notice, notice)
         |> refresh_status()}

      {:error, errors} when is_map(errors) ->
        {:noreply, assign(socket, errors: errors, draft: public_draft(params), notice: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           errors: %{"settings" => "Settings could not be saved: #{public_error(reason)}"},
           draft: public_draft(params),
           notice: nil
         )}
    end
  end

  defp enroll_candidate(enrollment, candidate_settings, public_params) do
    with {:ok, candidate_identity, ipv4} <- Tailscale.enroll(enrollment, candidate_settings),
         {:ok, settings} <- persist_enrollment(public_params, candidate_identity) do
      {:ok, settings, ipv4}
    end
  end

  defp finish_enrollment(socket, {:ok, settings, ipv4}) do
    socket
    |> assign(:enrolling, false)
    |> assign(:enrollment_task, nil)
    |> assign(:settings, settings)
    |> assign(:draft, %{})
    |> assign(:errors, %{})
    |> assign(:notice, "Tailscale joined successfully at #{ipv4}.")
    |> refresh_status()
  end

  defp finish_enrollment(socket, {:error, reason}) do
    socket = assign(socket, enrolling: false, enrollment_task: nil)
    {:noreply, socket} = handle_enrollment_error(socket, socket.assigns.draft, reason)
    socket
  end

  defp handle_enrollment_error(socket, _public_params, :missing_auth_key),
    do: enrollment_error(socket, "Enter a Tailscale auth key.")

  defp handle_enrollment_error(socket, _public_params, :invalid_auth_key),
    do: enrollment_error(socket, "The auth key format is not valid. Paste a tskey-auth-… key.")

  defp handle_enrollment_error(socket, _public_params, :internet_unavailable),
    do: enrollment_error(socket, "Internet is not available yet. Check the detected WAN port.")

  defp handle_enrollment_error(socket, _public_params, :connection_timeout),
    do: enrollment_error(socket, "Tailscale did not respond before the connection timed out.")

  defp handle_enrollment_error(socket, _public_params, :authentication_failed) do
    enrollment_error(
      socket,
      "Tailscale rejected the key. Generate a new one-use auth key and retry."
    )
  end

  defp handle_enrollment_error(socket, public_params, errors) when is_map(errors) do
    {:noreply, assign(socket, errors: errors, draft: public_draft(public_params), notice: nil)}
  end

  defp handle_enrollment_error(socket, _public_params, reason),
    do: enrollment_error(socket, "Enrollment failed: #{public_error(reason)}")

  defp persist_enrollment(public_params, candidate_identity) do
    previous_settings = Configuration.current()

    case Tailscale.commit_enrollment(candidate_identity) do
      {:ok, rollback} ->
        persist_committed_enrollment(public_params, previous_settings, rollback)

      {:error, _reason} = error ->
        _result = Tailscale.discard_enrollment(candidate_identity)
        error
    end
  end

  defp persist_committed_enrollment(public_params, previous_settings, rollback) do
    case Configuration.complete_enrollment(public_params) do
      {:ok, settings} ->
        _result = Tailscale.finalize_enrollment(rollback)
        {:ok, settings}

      {:error, _reason} = error ->
        _result = Tailscale.rollback_enrollment(rollback)
        _result = Configuration.restore(previous_settings)
        error
    end
  end

  defp enrollment_error(socket, message) do
    {:noreply, assign(socket, errors: %{"tailscale_auth_key" => message}, notice: nil)}
  end

  defp refresh_status(socket) do
    network = Network.status()

    assign(socket,
      settings: Configuration.current(),
      network: network,
      service: Service.status(),
      tailscale: Tailscale.status(),
      ethernet: ethernet_interfaces(network.interfaces),
      suggestion: network_suggestion(network)
    )
  end

  defp network_suggestion(network) do
    network.interfaces
    |> ethernet_interfaces()
    |> describe_ethernet()
  end

  defp describe_ethernet([]), do: {:error, "No Ethernet controller was detected."}

  defp describe_ethernet([_interface]) do
    {:warning,
     "One Ethernet controller was detected. Internet can work, but an isolated PLC connection requires a second controller."}
  end

  defp describe_ethernet(ethernet) do
    linked = Enum.count(ethernet, & &1.lower_up)
    {:ok, "#{length(ethernet)} Ethernet controllers detected; #{linked} currently have link."}
  end

  defp suggested_uplink(_ethernet, configured) when configured not in [nil, ""], do: configured

  defp suggested_uplink([interface], _configured), do: interface.hw_path

  defp suggested_uplink(ethernet, _configured) do
    ethernet
    |> Enum.filter(&(&1.lower_up and &1.connection == :internet))
    |> unique_interface_path()
  end

  defp suggested_machine(_ethernet, _uplink, configured) when configured not in [nil, ""],
    do: configured

  defp suggested_machine(ethernet, uplink, _configured) when uplink not in [nil, ""] do
    ethernet
    |> Enum.reject(&(&1.hw_path == uplink))
    |> unique_interface_path()
  end

  defp suggested_machine(_ethernet, _uplink, _configured), do: ""

  defp unique_interface_path([interface]), do: interface.hw_path
  defp unique_interface_path(_interfaces), do: ""

  defp interface_label(interface) do
    driver = interface.driver || "unknown driver"
    link = if interface.lower_up, do: "connected", else: "no cable"
    address = interface_addresses(interface)
    "#{interface.ifname} · #{driver} · #{link}#{address}"
  end

  defp interface_addresses(%{addresses: addresses}) when is_list(addresses) and addresses != [] do
    " · " <> Enum.join(addresses, ", ")
  end

  defp interface_addresses(_interface), do: ""
  defp ethernet_interfaces(interfaces), do: Enum.filter(interfaces, &(&1.kind == :ethernet))
  defp public_draft(params), do: Map.drop(params, ["tailscale_auth_key", "service_psk"])
  defp public_error(%PlcRemote.Error{reason: reason}), do: public_error(reason)
  defp public_error(reason) when is_atom(reason), do: Phoenix.Naming.humanize(reason)
  defp public_error(_reason), do: "unexpected error"
  defp selected?(left, right), do: to_string(left) == to_string(right)

  defp value(draft, field, fallback), do: Map.get(draft, field, fallback)

  defp checked?(draft, field, fallback) do
    case Map.fetch(draft, field) do
      {:ok, field_value} -> field_value in [true, "true", "on", "1", 1]
      :error -> fallback
    end
  end
end
