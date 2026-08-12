defmodule PlcRemote.Service.Actions do
  @moduledoc "Effect boundary for local AP, web runtime, and configuration transaction actions."

  require Logger

  alias PlcRemote.Service.{Portal, State}

  @intent_key {PlcRemote.Service, :service_intent}

  @spec enter_access_point(State.t(), :automatic | :recovery) ::
          {:ok, State.t()} | {:error, PlcRemote.Error.t(), State.t()}
  def enter_access_point(%State{} = state, mode) do
    leave_access_point(state)
    settings = state.settings
    ssid = service_ssid(settings.service.ssid_prefix)
    security = if mode == :automatic, do: :open, else: :wpa2

    with :ok <-
           platform().enter_access_point(
             settings.service,
             ssid,
             settings.uplink.regulatory_domain,
             security
           ),
         {ip, port} <- platform().web_bind(settings.service),
         {:ok, portal_pid} <- PlcRemote.Service.WebSupervisor.start_server(ip, port) do
      monitor_ref = Process.monitor(portal_pid)
      put_intent(mode)

      Logger.info(
        "#{label(mode)} active on SSID #{inspect(ssid)} at http://#{settings.service.address}/"
      )

      {:ok, %{state | portal: %Portal{pid: portal_pid, monitor_ref: monitor_ref}, ssid: ssid}}
    else
      {:error, reason} ->
        platform().leave_access_point()

        error = %PlcRemote.Error{
          subsystem: :service,
          operation: :enter_access_point,
          reason: reason
        }

        Logger.error("Unable to start service access: #{inspect(reason)}")
        {:error, error, state}
    end
  end

  @spec leave_access_point(State.t()) :: State.t()
  def leave_access_point(%State{} = state) do
    if state.portal.pid do
      PlcRemote.Service.WebSupervisor.stop_server(state.portal.pid)
      demonitor(state.portal.monitor_ref)
    end

    case platform().leave_access_point() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Unable to disable service access point: #{inspect(reason)}")
    end

    %{state | portal: %Portal{}, ssid: nil, expires_at: nil}
  end

  @spec begin_transaction() :: :ok | {:error, term()}
  def begin_transaction, do: PlcRemote.Configuration.Transaction.begin()

  @spec commit_transaction() :: :ok | {:error, term()}
  def commit_transaction, do: PlcRemote.Configuration.Transaction.commit()

  @spec rollback_transaction() :: :ok | {:error, term()}
  def rollback_transaction, do: PlcRemote.Configuration.Transaction.rollback()

  @spec mark_commissioned() :: :ok | {:error, term()}
  def mark_commissioned, do: PlcRemote.Configuration.mark_commissioned()

  @spec clear_intent() :: :ok
  def clear_intent do
    :persistent_term.erase(@intent_key)
    :ok
  end

  @spec initial_intent() :: :automatic | :recovery | nil
  def initial_intent, do: :persistent_term.get(@intent_key, nil)

  defp put_intent(mode), do: :persistent_term.put(@intent_key, mode)
  defp demonitor(nil), do: :ok
  defp demonitor(reference), do: Process.demonitor(reference, [:flush])
  defp label(:automatic), do: "Open commissioning WLAN"
  defp label(:recovery), do: "Protected recovery mode"

  defp service_ssid(prefix) do
    suffix =
      platform().serial_number()
      |> String.replace(~r/[^A-Za-z0-9]/, "")
      |> String.slice(-6, 6)
      |> case do
        "" -> "SETUP"
        value -> String.upcase(value)
      end

    String.slice("#{prefix}-#{suffix}", 0, 32)
  end

  defp platform, do: PlcRemote.Service.Platform
end
