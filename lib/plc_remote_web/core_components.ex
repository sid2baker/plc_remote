defmodule PlcRemoteWeb.CoreComponents do
  @moduledoc false

  use Phoenix.Component

  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div class={["notice", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  attr :state, :atom, required: true
  attr :label, :string, required: true
  attr :detail, :string, default: nil

  def check_row(assigns) do
    ~H"""
    <div class={["check-row", check_class(@state)]}>
      <span class="check-icon" aria-hidden="true">{check_icon(@state)}</span>
      <div><strong>{@label}</strong><small :if={@detail}>{@detail}</small></div>
    </div>
    """
  end

  attr :errors, :map, required: true
  attr :field, :string, required: true

  def field_error(assigns) do
    ~H"""
    <p :if={message = @errors[@field]} class="field-error">{message}</p>
    """
  end

  defp check_class(:ok), do: "ok"
  defp check_class(:error), do: "error"
  defp check_class(_state), do: "pending"

  defp check_icon(:ok), do: "✓"
  defp check_icon(:error), do: "!"
  defp check_icon(_state), do: "…"
end
