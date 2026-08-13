defmodule PlcRemoteWeb.Layouts do
  use PlcRemoteWeb, :html

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover" />
        <meta name="theme-color" content="#123e56" />
        <meta name="robots" content="noindex,nofollow" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>PLC Remote Setup</title>
        <link rel="stylesheet" href="/assets/js/app.css" />
        <script defer type="module" src="/assets/js/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <header class="topbar">
      <div>
        <p class="eyebrow">LOCAL SERVICE ACCESS</p><h1>PLC Remote</h1>
      </div>
      <div class="status-row" aria-label="Gateway status">
        <span class="status" id="live-status">Live status</span>
      </div>
    </header>
    <main>{@inner_content}</main>
    <footer>PLC Remote · local configuration interface</footer>
    """
  end
end
