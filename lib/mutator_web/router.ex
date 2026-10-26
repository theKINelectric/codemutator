defmodule MutatorWeb.Router do
  use MutatorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MutatorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MutatorWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/runs", RunLive.Index, :index
    live "/runs/:id", RunLive.Show, :show
    get "/agents", AgentsPageController, :index
  end

  # Well-known service card at the root, agent pipeline.
  scope "/", MutatorWeb.API do
    pipe_through :api
    get "/agents.json", AgentsController, :show
  end

  # Agent API: loopback-trusted, stable JSON shapes (see /agents).
  scope "/api", MutatorWeb.API do
    pipe_through :api

    post "/runs", RunController, :create
    get "/runs/:id", RunController, :show
    get "/runs/:id/outcomes", RunController, :outcomes
    post "/runs/:id/cancel", RunController, :cancel
    get "/agents", AgentsController, :show
    get "/agents.json", AgentsController, :show
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:mutator, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MutatorWeb.Telemetry
    end
  end
end
