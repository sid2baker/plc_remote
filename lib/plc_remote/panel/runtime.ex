defmodule PlcRemote.Panel.Runtime do
  @moduledoc "Owns IPCBOX IN2, OUT1/OUT2, and USER1/USER2 resources."

  use GenServer

  require Logger

  alias PlcRemote.Events.{NetworkChanged, PanelChanged, ServiceChanged, TailscaleChanged}
  alias PlcRemote.Health.Alarm
  alias PlcRemote.Health.Alarms.PanelIOUnavailable
  alias PlcRemote.Panel.{Policy, Status}

  @input_active_level 0
  @hold_ms 3_000
  @cooldown_ms 30_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec status() :: Status.t()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl GenServer
  def init(_opts) do
    :ok = PlcRemote.Events.subscribe()
    specs = Application.get_env(:plc_remote, :ipcbox_io)

    state = %{
      specs: specs,
      required?: panel_required?(),
      input_2: nil,
      input_2_ref: nil,
      input_2_active: false,
      outputs: %{},
      output_levels: safe_levels(),
      network: nil,
      tailscale: nil,
      service: nil,
      hold_timer: nil,
      cooldown_until: nil,
      last_error: nil,
      published_status: nil
    }

    state = if is_map(specs), do: open_panel(state), else: state
    state = apply_current_policy(state)
    state = report_health(state)
    {:ok, publish_status(state)}
  end

  @impl GenServer
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  @impl GenServer
  def handle_info(%NetworkChanged{status: status}, state),
    do: {:noreply, update_policy(%{state | network: status})}

  def handle_info(%TailscaleChanged{status: status}, state),
    do: {:noreply, update_policy(%{state | tailscale: status})}

  def handle_info(%ServiceChanged{status: status}, state),
    do: {:noreply, update_policy(%{state | service: status})}

  def handle_info({:circuits_gpio, %{ref: reference, value: value}}, state)
      when reference == state.input_2_ref do
    active? = value == @input_active_level
    state = %{state | input_2_active: active?}
    {:noreply, update_input_hold(state, active?)}
  end

  def handle_info(:input_2_hold_complete, state) do
    state = %{state | hold_timer: nil}
    now = PlcRemote.Clock.now_ms()

    cond do
      not state.input_2_active ->
        {:noreply, state}

      not tailscale_enabled?() ->
        Logger.info("IPCBOX IN2 reconnect request ignored because Tailscale is disabled")
        {:noreply, state}

      cooldown_elapsed?(state.cooldown_until, now) ->
        Logger.info("IPCBOX IN2 requested an immediate Tailscale reconnect")
        PlcRemote.Tailscale.reconnect()
        {:noreply, publish_status(%{state | cooldown_until: now + @cooldown_ms})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_event, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    PlcRemote.FSM.cancel_timer(state.hold_timer)
    close_handle(state.input_2)

    Enum.each(state.outputs, fn {name, handle} ->
      _result = adapter().write(handle, Map.fetch!(safe_levels(), name))
      close_handle(handle)
    end)

    Alarm.clear(PanelIOUnavailable)
    :ok
  end

  defp open_panel(state) do
    {input, input_ref, input_active, input_error} = open_input(state.specs.input_2)

    {outputs, output_errors} =
      Enum.reduce(output_specs(state.specs), {%{}, []}, fn {name, spec, initial},
                                                           {outputs, errors} ->
        case adapter().open_output(spec, initial) do
          {:ok, handle} -> {Map.put(outputs, name, handle), errors}
          {:error, reason} -> {outputs, [{name, reason} | errors]}
        end
      end)

    errors = List.wrap(input_error) ++ Enum.reverse(output_errors)

    %{
      state
      | input_2: input,
        input_2_ref: input_ref,
        input_2_active: input_active,
        outputs: outputs,
        last_error: panel_error(errors)
    }
  end

  defp open_input(spec) do
    case adapter().open_input(spec) do
      {:ok, input, reference} ->
        {input, reference, adapter().read(input) == @input_active_level, nil}

      {:error, reason} ->
        {nil, nil, false, {:input_2, reason}}
    end
  end

  defp output_specs(specs) do
    levels = safe_levels()

    [
      {:output_1, specs.output_1, levels.output_1},
      {:output_2, specs.output_2, levels.output_2},
      {:user_1, specs.user_1, levels.user_1},
      {:user_2, specs.user_2, levels.user_2}
    ]
  end

  defp apply_current_policy(state) do
    state
    |> Map.put(:network, current_status(PlcRemote.Network.Runtime, &PlcRemote.Network.status/0))
    |> Map.put(
      :tailscale,
      current_status(PlcRemote.Tailscale.Runtime, &PlcRemote.Tailscale.status/0)
    )
    |> Map.put(:service, current_status(PlcRemote.Service.Runtime, &PlcRemote.Service.status/0))
    |> update_policy()
  end

  defp current_status(process, read_status) do
    if Process.whereis(process), do: read_status.(), else: nil
  catch
    :exit, _reason -> nil
  end

  defp update_policy(state) do
    desired = Policy.levels(state.network, state.tailscale, state.service)
    {levels, errors} = write_changed_outputs(state, desired)

    error =
      case errors do
        [] -> state.last_error
        errors -> panel_error(errors)
      end

    state = %{state | output_levels: levels, last_error: error}
    state |> report_health() |> publish_status()
  end

  defp write_changed_outputs(state, desired) do
    Enum.reduce(desired, {state.output_levels, []}, fn {name, value}, result ->
      write_output(state.outputs, name, value, result)
    end)
  end

  defp write_output(outputs, name, value, {levels, errors}) do
    case {Map.get(outputs, name), Map.get(levels, name)} do
      {nil, _current} ->
        {levels, errors}

      {_handle, ^value} ->
        {levels, errors}

      {handle, _current} ->
        record_output_write(adapter().write(handle, value), name, value, levels, errors)
    end
  end

  defp record_output_write(:ok, name, value, levels, errors),
    do: {Map.put(levels, name, value), errors}

  defp record_output_write({:error, reason}, name, _value, levels, errors),
    do: {levels, [{name, reason} | errors]}

  defp update_input_hold(state, true) do
    if is_reference(state.hold_timer) do
      publish_status(state)
    else
      timer = PlcRemote.Clock.send_after(self(), :input_2_hold_complete, @hold_ms)
      publish_status(%{state | hold_timer: timer})
    end
  end

  defp update_input_hold(state, false) do
    PlcRemote.FSM.cancel_timer(state.hold_timer)
    publish_status(%{state | hold_timer: nil})
  end

  defp report_health(%{required?: false} = state) do
    Alarm.clear(PanelIOUnavailable)
    state
  end

  defp report_health(state) do
    unavailable? =
      not is_nil(state.last_error) or map_size(state.outputs) != 4 or is_nil(state.input_2)

    Alarm.report(PanelIOUnavailable, unavailable?, state.last_error)
    state
  end

  defp publish_status(state) do
    status = build_status(state)

    if status != state.published_status,
      do: PlcRemote.Events.publish(%PanelChanged{status: status})

    %{state | published_status: status}
  end

  defp build_status(%{required?: false, last_error: error}) do
    %Status{
      available: :not_configured,
      input_2: :unavailable,
      output_1: :unavailable,
      output_2: :unavailable,
      user_1: :unavailable,
      user_2: :unavailable,
      last_error: error
    }
  end

  defp build_status(state) do
    %Status{
      available:
        if(map_size(state.outputs) == 4 and gpio_handle?(state.input_2),
          do: :available,
          else: :unavailable
        ),
      input_2:
        if(gpio_handle?(state.input_2),
          do: input_state(state.input_2_active),
          else: :unavailable
        ),
      output_1: output_state(state, :output_1, 1),
      output_2: output_state(state, :output_2, 1),
      user_1: output_state(state, :user_1, 0),
      user_2: output_state(state, :user_2, 0),
      last_error: state.last_error
    }
  end

  defp output_state(state, name, on_level) do
    if Map.has_key?(state.outputs, name) do
      if Map.get(state.output_levels, name) == on_level, do: :on, else: :off
    else
      :unavailable
    end
  end

  defp gpio_handle?(value), do: is_pid(value) or is_reference(value) or is_map(value)
  defp input_state(true), do: :active
  defp input_state(false), do: :inactive
  defp tailscale_enabled?, do: PlcRemote.Configuration.current().tailscale.enabled
  defp cooldown_elapsed?(nil, _now), do: true
  defp cooldown_elapsed?(until, now), do: now >= until

  defp safe_levels, do: %{output_1: 0, output_2: 0, user_1: 1, user_2: 1}

  defp panel_error([]), do: nil

  defp panel_error(errors) do
    %PlcRemote.Error{subsystem: :panel, operation: :initialize_or_write, reason: errors}
  end

  defp panel_required?, do: Application.get_env(:plc_remote, :panel_required, false)
  defp close_handle(nil), do: :ok
  defp close_handle(handle), do: adapter().close(handle)
  defp adapter, do: Application.fetch_env!(:plc_remote, :gpio_adapter)
end
