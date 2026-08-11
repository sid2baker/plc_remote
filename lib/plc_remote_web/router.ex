defmodule PlcRemoteWeb.Router do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias PlcRemote.{
    Configuration,
    FirmwareValidator,
    NetworkManager,
    RecoveryManager,
    ServiceMode,
    TailscaleManager
  }

  alias PlcRemoteWeb.Page

  plug(Plug.Static,
    at: "/",
    from: {:plc_remote, "priv/static"},
    gzip: false,
    only: ~w(assets manifest.webmanifest service-worker.js)
  )

  plug(:put_secret_key_base)

  plug(Plug.Session,
    store: :cookie,
    key: "_plc_remote_service",
    signing_salt: "service-mode-v1",
    same_site: "Strict",
    http_only: true,
    secure: false,
    max_age: 7_200
  )

  plug(:fetch_session)

  plug(Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["application/x-www-form-urlencoded"],
    length: 64_000
  )

  plug(Plug.CSRFProtection)
  plug(:match)
  plug(:dispatch)

  get "/" do
    ServiceMode.touch()
    render_settings(conn, Configuration.get(), %{}, nil)
  end

  post "/settings" do
    ServiceMode.touch()

    case Configuration.update(conn.body_params) do
      {:ok, settings} ->
        render_settings(conn, settings, %{}, "Settings saved and applied.")

      {:error, errors} when is_map(errors) ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_settings(Configuration.get(), errors, nil)

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> render_settings(Configuration.get(), %{"settings" => "could not be persisted"}, nil)
    end
  end

  post "/service/exit" do
    if ServiceMode.status().mode == :automatic do
      conn
      |> security_headers()
      |> put_resp_content_type("text/plain")
      |> send_resp(409, "The open setup WLAN remains active until tailnet enrollment succeeds.")
    else
      Task.start(fn ->
        Process.sleep(500)
        ServiceMode.deactivate()
      end)

      conn
      |> security_headers()
      |> put_resp_content_type("text/html")
      |> send_resp(
        200,
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="/assets/app.css"><title>Service mode closed</title></head>
        <body><main class="closed"><h1>Settings complete</h1><p>Service Wi-Fi is shutting down. You may close this page.</p></main></body></html>
        """
      )
    end
  end

  get "/api/status" do
    payload = %{
      commissioned: Configuration.get().commissioned,
      firmware: safe_firmware_status(),
      network: safe_network_status(),
      recovery: safe_recovery_status(),
      service_mode: ServiceMode.status(),
      tailscale: safe_tailscale_status()
    }

    conn
    |> security_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  get "/*path" do
    redirect_to_portal(conn)
  end

  match _ do
    conn
    |> security_headers()
    |> send_resp(404, "Not found")
  end

  defp render_settings(conn, settings, errors, notice) do
    assigns = %{
      csrf_token: Plug.CSRFProtection.get_csrf_token(),
      errors: errors,
      firmware: safe_firmware_status(),
      network: safe_network_status(),
      recovery: safe_recovery_status(),
      notice: notice,
      service: ServiceMode.status(),
      settings: settings,
      tailscale: safe_tailscale_status()
    }

    body = assigns |> Page.render() |> IO.iodata_to_binary()

    conn
    |> security_headers()
    |> put_resp_content_type("text/html")
    |> send_resp(conn.status || 200, body)
  end

  defp redirect_to_portal(conn) do
    conn
    |> security_headers()
    |> put_resp_header("location", "http://plc.setup/")
    |> send_resp(302, "")
  end

  defp security_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store, max-age=0")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    )
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
  end

  defp put_secret_key_base(conn, _opts) do
    web_secret = Configuration.get().service.web_secret
    secret = :crypto.hash(:sha512, "plc-remote-service:" <> web_secret) |> Base.encode64()
    %{conn | secret_key_base: secret}
  end

  defp safe_firmware_status do
    FirmwareValidator.status()
  catch
    :exit, _reason -> %{firmware: :unknown, last_action: nil, last_error: "Validator unavailable"}
  end

  defp safe_recovery_status do
    RecoveryManager.status()
  catch
    :exit, _reason -> %{consecutive_reboots: 0, last_action: nil, offline_for_seconds: nil}
  end

  defp safe_network_status do
    NetworkManager.status()
  catch
    :exit, _reason ->
      %{
        applied_at: nil,
        connection: nil,
        interfaces: [],
        last_error: "Network manager is not running",
        roles: %{}
      }
  end

  defp safe_tailscale_status do
    TailscaleManager.status()
  catch
    :exit, _reason ->
      %{
        active_sessions: 0,
        destination: nil,
        failure_count: 0,
        listen_port: nil,
        reason: "Tailscale manager is not running",
        retry_in_seconds: nil,
        state: :unavailable,
        tailnet_ipv4: nil
      }
  end
end
