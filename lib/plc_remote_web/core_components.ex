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

  attr :errors, :map, required: true
  attr :field, :string, required: true

  def field_error(assigns) do
    ~H"""
    <p :if={message = @errors[@field]} class="field-error">{message}</p>
    """
  end
end
