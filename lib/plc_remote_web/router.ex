defmodule PlcRemoteWeb.Router do
  use PlcRemoteWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PlcRemoteWeb.Layouts, :root}
    plug :protect_from_forgery
  end

  scope "/", PlcRemoteWeb do
    pipe_through :browser

    live "/", ConfigurationLive, :index
    get "/generate_204", CaptiveController, :redirect
    get "/gen_204", CaptiveController, :redirect
    get "/hotspot-detect.html", CaptiveController, :redirect
    get "/ncsi.txt", CaptiveController, :redirect
    get "/connecttest.txt", CaptiveController, :redirect
    get "/*path", CaptiveController, :redirect
  end
end
