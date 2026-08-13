defmodule PlcRemote.Service.Actions do
  @moduledoc "Effect boundary for the WPA2 service access point and web runtime."

  require Logger

  alias PlcRemote.Service.{Portal, State}

  @spec enter_access_point(State.t()) ::
          {:ok, State.t()} | {:error, PlcRemote.Error.t(), State.t()}
  def enter_access_point(%State{} = state) do
    state = leave_access_point(state)
    settings = state.settings
    ssid = service_ssid(settings.service.ssid_prefix)

    case PlcRemote.Service.Platform.enter_access_point(
           settings.service,
           ssid,
           settings.uplink.regulatory_domain
         ) do
      :ok ->
        start_portal(state, settings, ssid)

      {:error, reason} ->
        enter_failed(state, reason)
    end
  end

  defp start_portal(state, settings, ssid) do
    case start_web_server(PlcRemote.Service.Platform.web_bind(settings.service)) do
      {:ok, portal_pid} ->
        monitor_ref = Process.monitor(portal_pid)
        routing = enable_routing(settings)

        Logger.info(
          "Service WLAN active on #{inspect(ssid)} at http://#{settings.service.address}/"
        )

        {:ok,
         %{
           state
           | portal: %Portal{pid: portal_pid, monitor_ref: monitor_ref},
             routing: routing,
             ssid: ssid
         }}

      {:error, reason} ->
        enter_failed(state, reason)
    end
  end

  defp start_web_server({ip, port}), do: PlcRemote.Service.WebSupervisor.start_server(ip, port)

  defp enter_failed(state, reason) do
    _result = PlcRemote.Service.Router.disable()
    _result = PlcRemote.Service.Platform.leave_access_point()

    error = %PlcRemote.Error{
      subsystem: :service,
      operation: :enter_access_point,
      reason: reason
    }

    Logger.error("Unable to start service access: #{inspect(reason)}")
    {:error, error, state}
  end

  @spec leave_access_point(State.t()) :: State.t()
  def leave_access_point(%State{} = state) do
    stop_portal(state.portal)

    case PlcRemote.Service.Router.disable() do
      :ok -> :ok
      {:error, reason} -> Logger.error("Unable to disable service routing: #{inspect(reason)}")
    end

    case PlcRemote.Service.Platform.leave_access_point() do
      :ok -> :ok
      {:error, reason} -> Logger.error("Unable to disable service WLAN: #{inspect(reason)}")
    end

    %{state | portal: %Portal{}, routing: :inactive, ssid: nil}
  end

  defp stop_portal(%Portal{pid: pid, monitor_ref: monitor_ref}) when is_pid(pid) do
    if Process.alive?(pid), do: PlcRemote.Service.WebSupervisor.stop_server(pid)
    demonitor(monitor_ref)
  catch
    :exit, _reason -> :ok
  end

  defp stop_portal(_portal), do: :ok

  defp enable_routing(settings) do
    case PlcRemote.Service.Router.enable(settings) do
      :ok ->
        :active

      {:error, reason} ->
        Logger.warning("Service WLAN started without Internet routing: #{inspect(reason)}")
        :unavailable
    end
  end

  defp demonitor(nil), do: :ok
  defp demonitor(reference), do: Process.demonitor(reference, [:flush])

  defp service_ssid(prefix) do
    suffix =
      PlcRemote.Service.Platform.serial_number()
      |> String.replace(~r/[^A-Za-z0-9]/, "")
      |> String.slice(-6, 6)
      |> case do
        "" -> "SETUP"
        value -> String.upcase(value)
      end

    String.slice("#{prefix}-#{suffix}", 0, 32)
  end
end
