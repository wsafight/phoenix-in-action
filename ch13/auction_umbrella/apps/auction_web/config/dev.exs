# Since configuration is shared in umbrella projects, this file
# should only configure the :auction_web application itself
# and only for organization purposes. All other config goes to
# the umbrella root.
import Config

# For development, we disable any cache and enable
# debugging and code reloading.
config :auction_web, AuctionWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "BOXCxqrqQfa7YvmeIHA2Ojl430zkjfOogywxCF9k8HaknMngwrIMGUItbB21r0YP",
  watchers: []

# Watch static and templates for browser reloading.
config :auction_web, AuctionWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/auction_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]
