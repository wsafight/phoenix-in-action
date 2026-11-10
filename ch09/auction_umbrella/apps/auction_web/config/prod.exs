# Since configuration is shared in umbrella projects, this file
# should only configure the :auction_web application itself
# and only for organization purposes. All other config goes to
# the umbrella root.
import Config

# For production, don't forget to configure the url host
# to something meaningful, Phoenix uses this information
# when generating URLs.
config :auction_web, AuctionWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Runtime production configuration, including acquiring
# host and port from environment variables, is handled by
# config/runtime.exs in the umbrella root.
