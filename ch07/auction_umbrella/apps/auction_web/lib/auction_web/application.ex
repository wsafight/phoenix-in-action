defmodule AuctionWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      # AuctionWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: AuctionWeb.PubSub},
      # Start DNS cluster
      {DNSCluster, query: Application.get_env(:auction_web, :dns_cluster_query) || :ignore},
      # Start the Endpoint (http/https)
      AuctionWeb.Endpoint
      # Start a worker by calling: AuctionWeb.Worker.start_link(arg)
      # {AuctionWeb.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AuctionWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
