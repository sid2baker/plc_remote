defmodule PlcRemote.ServiceMode do
  @moduledoc """
  Controls automatic first-boot commissioning and physically enabled recovery.

  An uncommissioned target starts an open setup WLAN automatically and keeps it
  available until Tailscale enrollment succeeds. After commissioning, the GPIO
  must remain asserted for the hold duration to start a timeout-limited WPA2
  recovery access point.
  """

  use GenServer

  require Logger

  alias PlcRemote.{Commissioning, Configuration}
  alias PlcRemote.ServiceMode.{Platform, WebSupervisor}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Starts service mode immediately. Intended for local recovery and tests."
  @spec activate() :: :ok | {:error, term()}
  def activate, do: GenServer.call(__MODULE__, :activate, 30_000)

  @doc "Stops the service access point and restores normal Wi-Fi operation."
  @spec deactivate() :: :ok | {:error, :commissioning_required}
  def deactivate, do: GenServer.call(__MODULE__, :deactivate, 30_000)

  @doc "Returns whether the service access point is active."
  @spec active?() :: boolean()
  def active?, do: GenServer.call(__MODULE__, :active?)

  @doc "Returns non-secret service-mode status."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Resets the service-mode inactivity timer after an operator action."
  @spec touch() :: :ok
  def touch, do: GenServer.cast(__MODULE__, :touch)

  @impl GenServer
  def init(_opts) do
    settings = Configuration.get()

    state = %{
      settings: settings,
      automatic_retry_timer: nil,
      gpio: nil,
      gpio_ref: nil,
      gpio_error: nil,
      hold_timer: nil,
      mode: nil,
      portal_pid: nil,
      portal_ref: nil,
      timeout_timer: nil,
      expires_at: nil,
      ssid: nil
    }

    state = open_gpio(state)

    state =
      if automatic_commissioning?(settings) do
        schedule_automatic_retry(state, 0)
      else
        state
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:activate, _from, state) do
    {reply, state} = activate_service_mode(state, :recovery)
    {:reply, reply, state}
  end

  def handle_call(
        :deactivate,
        _from,
        %{mode: :automatic, settings: %{commissioned: false}} = state
      ) do
    {:reply, {:error, :commissioning_required}, state}
  end

  def handle_call(:deactivate, _from, state) do
    {:reply, :ok, stop_service_mode(state)}
  end

  def handle_call(:active?, _from, state) do
    {:reply, not is_nil(state.portal_pid), state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      active: not is_nil(state.portal_pid),
      address: state.settings.service.address,
      expires_in_seconds: expires_in_seconds(state.expires_at),
      gpio_error: state.gpio_error,
      gpio_spec: state.settings.service.gpio_spec,
      mode: state.mode,
      secured: state.mode == :recovery,
      ssid: state.ssid
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_cast(:touch, state) do
    {:noreply, reset_timeout(state)}
  end

  @impl GenServer
  def handle_info(
        {:circuits_gpio, %{ref: reference, value: value}},
        %{gpio_ref: reference} = state
      ) do
    {:noreply, handle_gpio_value(state, value)}
  end

  def handle_info(:activate_automatic_commissioning, state) do
    state = %{state | automatic_retry_timer: nil}

    if automatic_commissioning?(state.settings) and is_nil(state.portal_pid) do
      case activate_service_mode(state, :automatic) do
        {:ok, state} -> {:noreply, state}
        {{:error, _reason}, state} -> {:noreply, schedule_automatic_retry(state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:gpio_hold_complete, state) do
    state = %{state | hold_timer: nil}

    if gpio_asserted?(state) do
      {_reply, state} = activate_service_mode(state, :recovery)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:service_timeout, state) do
    Logger.info("Service mode timed out; restoring normal Wi-Fi operation")
    {:noreply, stop_service_mode(%{state | timeout_timer: nil, expires_at: nil})}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{portal_ref: reference} = state) do
    Logger.error("Service web server stopped: #{inspect(reason)}")
    automatic? = state.mode == :automatic and not state.settings.commissioned
    cancel_timer(state.timeout_timer)
    Platform.leave_access_point()

    state =
      %{
        state
        | mode: nil,
          portal_pid: nil,
          portal_ref: nil,
          timeout_timer: nil,
          expires_at: nil,
          ssid: nil
      }

    state = if automatic?, do: schedule_automatic_retry(state), else: state
    {:noreply, state}
  end

  def handle_info({:settings_updated, settings, _auth_key}, state) do
    gpio_changed? =
      settings.service.gpio_spec != state.settings.service.gpio_spec or
        settings.service.active_level != state.settings.service.active_level

    state = %{state | settings: settings}
    state = if gpio_changed?, do: reopen_gpio(state), else: state

    cond do
      settings.commissioned and state.mode == :automatic ->
        Logger.info("Tailnet enrollment complete; stopping open commissioning WLAN")
        {:noreply, stop_service_mode(state)}

      automatic_commissioning?(settings) and is_nil(state.portal_pid) ->
        {:noreply, schedule_automatic_retry(state, 0)}

      true ->
        {:noreply, reset_timeout(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _state = stop_service_mode(state)
    close_gpio(state.gpio)
    :ok
  end

  defp activate_service_mode(%{portal_pid: pid} = state, _mode) when is_pid(pid) do
    {:ok, reset_timeout(state)}
  end

  defp activate_service_mode(state, mode) do
    settings = state.settings
    ssid = service_ssid(settings.service.ssid_prefix)
    security = if mode == :automatic, do: :open, else: :wpa2

    with :ok <-
           Platform.enter_access_point(
             settings.service,
             ssid,
             settings.uplink.regulatory_domain,
             security
           ),
         {ip, port} <- Platform.web_bind(settings.service),
         {:ok, portal_pid} <- WebSupervisor.start_server(ip, port) do
      portal_ref = Process.monitor(portal_pid)

      Logger.info(
        "#{service_mode_label(mode)} active on SSID #{inspect(ssid)} at " <>
          "http://#{settings.service.address}/"
      )

      new_state =
        state
        |> Map.put(:mode, mode)
        |> Map.put(:portal_pid, portal_pid)
        |> Map.put(:portal_ref, portal_ref)
        |> Map.put(:ssid, ssid)
        |> reset_timeout()

      {:ok, new_state}
    else
      {:error, reason} ->
        Platform.leave_access_point()
        Logger.error("Unable to start service mode: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end

  defp stop_service_mode(state) do
    cancel_timer(state.automatic_retry_timer)
    cancel_timer(state.hold_timer)
    cancel_timer(state.timeout_timer)

    if state.portal_pid do
      _result = WebSupervisor.stop_server(state.portal_pid)
      demonitor(state.portal_ref)
      Platform.leave_access_point()
    end

    %{
      state
      | automatic_retry_timer: nil,
        hold_timer: nil,
        mode: nil,
        portal_pid: nil,
        portal_ref: nil,
        timeout_timer: nil,
        expires_at: nil,
        ssid: nil
    }
  end

  defp handle_gpio_value(state, value) do
    if value == state.settings.service.active_level do
      arm_hold_timer(state)
    else
      cancel_timer(state.hold_timer)
      %{state | hold_timer: nil}
    end
  end

  defp arm_hold_timer(%{portal_pid: pid} = state) when is_pid(pid), do: state
  defp arm_hold_timer(%{hold_timer: timer} = state) when is_reference(timer), do: state

  defp arm_hold_timer(state) do
    timer = Process.send_after(self(), :gpio_hold_complete, state.settings.service.hold_ms)
    %{state | hold_timer: timer}
  end

  defp gpio_asserted?(%{gpio: nil}), do: false

  defp gpio_asserted?(state) do
    Platform.read_gpio(state.gpio) == state.settings.service.active_level
  catch
    _kind, _reason -> false
  end

  defp open_gpio(state) do
    case Platform.open_gpio(state.settings.service.gpio_spec) do
      {:ok, gpio, reference} ->
        state = %{state | gpio: gpio, gpio_ref: reference, gpio_error: nil}
        handle_gpio_value(state, Platform.read_gpio(gpio))

      {:error, :not_available_on_host} ->
        %{state | gpio_error: "not available on host"}

      {:error, reason} ->
        Logger.error(
          "Unable to monitor service GPIO #{inspect(state.settings.service.gpio_spec)}: #{inspect(reason)}"
        )

        %{state | gpio_error: inspect(reason)}
    end
  end

  defp reopen_gpio(state) do
    close_gpio(state.gpio)
    state = %{state | gpio: nil, gpio_ref: nil, gpio_error: nil}
    open_gpio(state)
  end

  defp close_gpio(nil), do: :ok
  defp close_gpio(gpio), do: Platform.close_gpio(gpio)

  defp reset_timeout(%{portal_pid: nil} = state), do: state
  defp reset_timeout(%{mode: :automatic} = state), do: state

  defp reset_timeout(state) do
    cancel_timer(state.timeout_timer)
    timeout_ms = state.settings.service.timeout_ms
    timer = Process.send_after(self(), :service_timeout, timeout_ms)

    %{
      state
      | timeout_timer: timer,
        expires_at: System.monotonic_time(:millisecond) + timeout_ms
    }
  end

  defp expires_in_seconds(nil), do: nil

  defp expires_in_seconds(expires_at) do
    remaining = expires_at - System.monotonic_time(:millisecond)
    max(div(remaining, 1_000), 0)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _result = Process.cancel_timer(timer)
    :ok
  end

  defp demonitor(nil), do: :ok

  defp demonitor(reference) do
    Process.demonitor(reference, [:flush])
    :ok
  end

  defp automatic_commissioning?(settings) do
    Application.get_env(:plc_remote, :auto_commissioning, true) and
      Commissioning.required?(settings)
  end

  defp schedule_automatic_retry(state, delay_ms \\ 5_000)

  defp schedule_automatic_retry(%{automatic_retry_timer: timer} = state, _delay_ms)
       when is_reference(timer),
       do: state

  defp schedule_automatic_retry(state, delay_ms) do
    timer = Process.send_after(self(), :activate_automatic_commissioning, delay_ms)
    %{state | automatic_retry_timer: timer}
  end

  defp service_mode_label(:automatic), do: "Open commissioning WLAN"
  defp service_mode_label(:recovery), do: "Protected recovery mode"

  defp service_ssid(prefix) do
    suffix =
      Platform.serial_number()
      |> String.replace(~r/[^A-Za-z0-9]/, "")
      |> String.slice(-6, 6)
      |> case do
        "" -> "SETUP"
        value -> String.upcase(value)
      end

    String.slice("#{prefix}-#{suffix}", 0, 32)
  end
end
