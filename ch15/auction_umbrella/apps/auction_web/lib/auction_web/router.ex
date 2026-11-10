defmodule AuctionWeb.Router do
  use AuctionWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AuctionWeb.Authenticator
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug AuctionWeb.Authenticator
  end

  scope "/", AuctionWeb do
    pipe_through :browser

    get "/", ItemController, :index

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    resources "/items", ItemController,
      only: [
        :index,
        :show,
        :new,
        :create,
        :edit,
        :update
      ] do
      resources "/bids", BidController, only: [:create]
    end

    resources "/users", UserController, only: [:show, :new, :create]
  end

  # LiveView routes: same :browser pipeline for the initial HTML render,
  # then the socket upgrade picks the session up via connect_info.
  live_session :default,
    on_mount: [{AuctionWeb.UserAuthLive, :default}] do
    scope "/", AuctionWeb do
      pipe_through :browser

      live "/live/items/:id", ItemLive.Show, :show
    end
  end

  # Other scopes may use custom stacks.
  scope "/api", AuctionWeb.Api do
    pipe_through :api

    resources "/items", ItemController, only: [:index, :show, :create] do
      resources "/bids", BidController, only: [:create]
    end
  end
end
