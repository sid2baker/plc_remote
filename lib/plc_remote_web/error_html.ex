defmodule PlcRemoteWeb.ErrorHTML do
  use PlcRemoteWeb, :html

  @spec render(String.t(), map()) :: Phoenix.LiveView.Rendered.t()
  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)

    assigns = %{status: status}

    ~H"""
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8" /><meta name="viewport" content="width=device-width" /></head>
      <body>
        <main class="closed">
          <h1>{@status}</h1>
        </main>
      </body>
    </html>
    """
  end
end
