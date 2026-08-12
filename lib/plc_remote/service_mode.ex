defmodule PlcRemote.ServiceMode do
  @moduledoc """
  Controls automatic first-boot commissioning and physically enabled recovery.

  An uncommissioned target starts an open setup WLAN automatically and keeps it
  available until the explicit final verification succeeds. After commissioning,
  the GPIO must remain asserted for the hold duration to start a timeout-limited
  WPA2 recovery access point.
  """

  use GenServer

  require Logger

  @default_verification_check_ms 2_000
  @default_verification_timeout_ms 180_000
  @intent_key {__MODULE__, :service_intent}

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

  @doc "Stops the local service access point."
  @spec deactivate() :: :ok | {:error, :commissioning_required}
  def deactivate, do: GenServer.call(__MODULE__, :deactivate, 30_000)

  @doc "Returns whether service mode or its protected final handoff is active."
  @spec active?() :: boolean()
  def active?, do: GenServer.call(__MODULE__, :active?)

  @doc "Returns non-secret service-mode status."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Starts the bounded final test; success closes the AP and failure keeps it active."
  @spec finish_commissioning() :: {:ok, :verifying} | {:error, term()}
  def finish_commissioning, do: GenServer.call(__MODULE__, :finish_commissioning, 30_000)

  @doc "Resets the service-mode inactivity timer after an operator action."
  @spec touch() :: :ok
  def touch, do: GenServer.cast(__MODULE__, :touch)

  @impl GenServer
  def init(_opts) do
    settings = Configuration.get()

    state = %{
      settings: settings,
      service_retry_timer: nil,
      retry_mode: nil,
      gpio: nil,
      gpio_ref: nil,
      gpio_error: nil,
      hold_timer: nil,
      mode: nil,
      portal_pid: nil,
      portal_ref: nil,
      timeout_timer: nil,
      expires_at: nil,
      ssid: nil,
      verification_timer: nil,
      verification_deadline: nil,
      verification_origin: nil,
      verification: idle_verification()
    }

    state = open_gpio(state)

    state =
      case initial_service_mode(settings) do
        nil -> state
        mode -> schedule_service_retry(state, mode, 0)
      end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:activate, _from, %{mode: :verifying} = state) do
    {:reply, {:error, :verification_in_progress}, state}
  end

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
    state = rollback_unverified_changes(state)
    clear_service_intent()
    {:reply, :ok, stop_service_mode(state)}
  end

  def handle_call(:finish_commissioning, _from, %{mode: :verifying} = state) do
    {:reply, {:ok, :verifying}, state}
  end

  def handle_call(
        :finish_commissioning,
        _from,
        %{mode: :automatic, settings: %{commissioned: false}} = state
      ) do
    {:reply, {:ok, :verifying}, start_final_verification(state, :automatic)}
  end

  def handle_call(
        :finish_commissioning,
        _from,
        %{mode: :recovery, settings: %{commissioned: true}} = state
      ) do
    {:reply, {:ok, :verifying}, start_final_verification(state, :recovery)}
  end

  def handle_call(:finish_commissioning, _from, state) do
    {:reply, {:error, :automatic_commissioning_not_active}, state}
  end

  def handle_call(:active?, _from, state) do
    {:reply, not is_nil(state.mode), state}
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
      ssid: state.ssid,
      verification: state.verification
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

  def handle_info({:activate_service_mode, mode}, state) do
    state = %{state | service_retry_timer: nil, retry_mode: nil}

    if service_mode_required?(state, mode) and is_nil(state.portal_pid) do
      case activate_service_mode(state, mode) do
        {:ok, state} -> {:noreply, state}
        {{:error, _reason}, state} -> {:noreply, schedule_service_retry(state, mode)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:begin_commissioning_verification, %{mode: mode} = state)
      when mode in [:automatic, :recovery] do
    Logger.info("Verifying Ethernet Internet and Tailscale before closing the setup AP")
    cancel_timer(state.timeout_timer)

    state =
      state
      |> Map.put(:mode, :verifying)
      |> Map.put(:timeout_timer, nil)
      |> Map.put(:expires_at, nil)
      |> Map.put(
        :verification_deadline,
        System.monotonic_time(:millisecond) + verification_timeout_ms()
      )
      |> schedule_verification()

    {:noreply, state}
  end

  def handle_info(:begin_commissioning_verification, state), do: {:noreply, state}

  def handle_info(:verify_commissioning, %{mode: :verifying} = state) do
    state = %{state | verification_timer: nil}
    checks = commissioning_checks()
    state = %{state | verification: %{state: :running, checks: checks, error: nil}}

    cond do
      Commissioning.verified?(checks) ->
        complete_commissioning(state)

      verification_expired?(state) ->
        restore_after_failed_verification(state, :verification_timeout)

      true ->
        {:noreply, schedule_verification(state)}
    end
  end

  def handle_info(:verify_commissioning, state), do: {:noreply, state}

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
    Logger.info("Service mode timed out; disabling the service access point")

    state =
      state
      |> Map.put(:timeout_timer, nil)
      |> Map.put(:expires_at, nil)
      |> rollback_unverified_changes()

    clear_service_intent()
    {:noreply, stop_service_mode(state)}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{portal_ref: reference} = state) do
    Logger.error("Service web server stopped: #{inspect(reason)}")
    restart_mode = restart_mode(state)
    cancel_timer(state.timeout_timer)
    cancel_timer(state.verification_timer)
    Platform.leave_access_point()

    state =
      state
      |> rollback_after_portal_crash(restart_mode)
      |> Map.merge(%{
        mode: nil,
        portal_pid: nil,
        portal_ref: nil,
        timeout_timer: nil,
        expires_at: nil,
        ssid: nil,
        verification_timer: nil,
        verification_deadline: nil,
        verification_origin: nil
      })

    {:noreply, schedule_service_retry(state, restart_mode)}
  end

  def handle_info({:settings_updated, settings, _auth_key}, state) do
    gpio_changed? =
      settings.service.gpio_spec != state.settings.service.gpio_spec or
        settings.service.active_level != state.settings.service.active_level

    state = %{state | settings: settings}
    state = if gpio_changed?, do: reopen_gpio(state), else: state

    if automatic_commissioning?(settings) and is_nil(state.portal_pid) and
         state.mode != :verifying do
      {:noreply, schedule_service_retry(state, :automatic, 0)}
    else
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
    # Clear any stale AP resources left by an untrappable manager kill before
    # configuring a fresh AP and listener.
    Platform.leave_access_point()
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

      put_service_intent(mode)

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
    cancel_timer(state.service_retry_timer)
    cancel_timer(state.hold_timer)
    cancel_timer(state.timeout_timer)
    cancel_timer(state.verification_timer)

    if state.portal_pid do
      _result = WebSupervisor.stop_server(state.portal_pid)
      demonitor(state.portal_ref)
      Platform.leave_access_point()
    end

    %{
      state
      | service_retry_timer: nil,
        retry_mode: nil,
        hold_timer: nil,
        mode: nil,
        portal_pid: nil,
        portal_ref: nil,
        timeout_timer: nil,
        expires_at: nil,
        ssid: nil,
        verification_timer: nil,
        verification_deadline: nil,
        verification_origin: nil
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

  defp arm_hold_timer(%{mode: :verifying} = state), do: state
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

  defp schedule_service_retry(state, mode, delay_ms \\ 5_000)

  defp schedule_service_retry(%{service_retry_timer: timer} = state, _mode, _delay_ms)
       when is_reference(timer),
       do: state

  defp schedule_service_retry(state, mode, delay_ms) when mode in [:automatic, :recovery] do
    timer = Process.send_after(self(), {:activate_service_mode, mode}, delay_ms)
    %{state | service_retry_timer: timer, retry_mode: mode}
  end

  defp schedule_service_retry(state, _mode, _delay_ms), do: state

  defp service_mode_required?(state, :automatic), do: automatic_commissioning?(state.settings)
  defp service_mode_required?(state, :recovery), do: state.settings.commissioned

  defp restart_mode(%{mode: :verifying, verification_origin: origin}), do: origin
  defp restart_mode(%{mode: mode}), do: mode

  defp rollback_after_portal_crash(state, :recovery), do: rollback_unverified_changes(state)
  defp rollback_after_portal_crash(state, _mode), do: state

  defp start_final_verification(state, origin) do
    Process.send_after(self(), :begin_commissioning_verification, 750)
    %{state | verification: running_verification(), verification_origin: origin}
  end

  defp suspend_access_point(state) do
    cancel_timer(state.timeout_timer)

    if state.portal_pid do
      _result = WebSupervisor.stop_server(state.portal_pid)
      demonitor(state.portal_ref)
      Platform.leave_access_point()
    end

    %{
      state
      | portal_pid: nil,
        portal_ref: nil,
        timeout_timer: nil,
        expires_at: nil,
        ssid: nil
    }
  end

  defp commissioning_checks do
    network = PlcRemote.NetworkManager.status()
    tailscale = PlcRemote.TailscaleManager.status()
    Commissioning.verification(network, tailscale)
  catch
    :exit, _reason -> %{internet: false, tailscale: false}
  end

  defp complete_commissioning(%{verification_origin: :automatic} = state) do
    case Configuration.mark_commissioned() do
      :ok ->
        complete_success(%{state | settings: Map.put(state.settings, :commissioned, true)})

      {:error, reason} ->
        restore_after_failed_verification(state, {:settings_persist_failed, reason})
    end
  end

  defp complete_commissioning(%{verification_origin: :recovery} = state) do
    case Configuration.commit_service_transaction() do
      :ok -> complete_success(state)
      {:error, reason} -> restore_after_failed_verification(state, {:commit_failed, reason})
    end
  end

  defp complete_success(state) do
    Logger.info("Final verification passed; closing the service AP")
    clear_service_intent()
    state = suspend_access_point(state)

    {:noreply,
     %{
       state
       | mode: nil,
         verification_deadline: nil,
         verification_origin: nil,
         verification: %{state: :passed, checks: state.verification.checks, error: nil}
     }}
  end

  defp restore_after_failed_verification(state, reason) do
    Logger.warning(
      "Final commissioning verification failed; setup AP remains active: #{inspect(reason)}"
    )

    origin = state.verification_origin
    verification = %{state: :failed, checks: state.verification.checks, error: inspect(reason)}

    state =
      state
      |> maybe_restore_snapshot()
      |> Map.put(:mode, origin)
      |> Map.put(:verification_deadline, nil)
      |> Map.put(:verification_origin, nil)
      |> Map.put(:verification, verification)
      |> reset_timeout()

    {:noreply, state}
  end

  defp rollback_unverified_changes(state) do
    case Configuration.rollback_service_transaction() do
      :ok -> %{state | settings: Configuration.get()}
      {:error, _reason} -> state
    end
  end

  defp maybe_restore_snapshot(state), do: rollback_unverified_changes(state)

  defp schedule_verification(state, delay_ms \\ nil) do
    delay_ms = delay_ms || verification_check_ms()
    timer = Process.send_after(self(), :verify_commissioning, delay_ms)
    %{state | verification_timer: timer}
  end

  defp verification_expired?(state) do
    System.monotonic_time(:millisecond) >= state.verification_deadline
  end

  defp verification_check_ms do
    Application.get_env(
      :plc_remote,
      :commissioning_verification_check_ms,
      @default_verification_check_ms
    )
  end

  defp verification_timeout_ms do
    Application.get_env(
      :plc_remote,
      :commissioning_verification_timeout_ms,
      @default_verification_timeout_ms
    )
  end

  defp idle_verification do
    %{state: :idle, checks: empty_checks(), error: nil}
  end

  defp running_verification do
    %{state: :starting, checks: empty_checks(), error: nil}
  end

  defp empty_checks do
    %{internet: false, tailscale: false}
  end

  defp initial_service_mode(settings) do
    cond do
      automatic_commissioning?(settings) -> :automatic
      settings.commissioned and :persistent_term.get(@intent_key, nil) == :recovery -> :recovery
      true -> nil
    end
  end

  defp put_service_intent(mode) when mode in [:automatic, :recovery] do
    :persistent_term.put(@intent_key, mode)
  end

  defp clear_service_intent do
    :persistent_term.erase(@intent_key)
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
