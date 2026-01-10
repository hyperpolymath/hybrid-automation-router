# SPDX-License-Identifier: MPL-2.0
defmodule HARWeb.Router do
  @moduledoc """
  Phoenix router for HAR web interface.

  Routes requests to the appropriate controllers and live views.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HARWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HARWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/transform", TransformLive, :index
    live "/graph/:id", GraphLive, :show
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:har, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HARWeb.Telemetry
    end
  end

  # API endpoints
  scope "/api", HARWeb do
    pipe_through :api

    post "/transform", TransformController, :transform
    post "/parse", TransformController, :parse
    get "/formats", TransformController, :formats
  end
end
