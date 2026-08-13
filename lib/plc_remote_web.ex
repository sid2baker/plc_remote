defmodule PlcRemoteWeb do
  @moduledoc false

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {PlcRemoteWeb.Layouts, :app}

      import PlcRemoteWeb.CoreComponents
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Phoenix.LiveView.Router
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import PlcRemoteWeb.CoreComponents
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
