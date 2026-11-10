import Config

if config_env() == :prod do
  config :auction_web, AuctionWeb.Endpoint,
    http: [:inet6, port: String.to_integer(System.get_env("PORT") || "4000")]
end
