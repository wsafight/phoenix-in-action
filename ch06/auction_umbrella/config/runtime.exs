import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. This replaces
# the old config/prod.secret.exs file.
if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config.exs, but you want to use a different
  # value for production and you most likely don't want to check this value
  # into version control, so we use an environment variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :auction_web, AuctionWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key to your
  # configuration above, like so:
  #
  #     https: [
  #       port: 443,
  #       cipher_suite: :strong,
  #       keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #       certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #     ]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
