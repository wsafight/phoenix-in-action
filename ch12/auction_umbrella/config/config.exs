# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
import Config

# By default, the umbrella project as well as each child
# application will require this configuration file, ensuring
# they all use the same configuration. While one could
# configure all applications here, we prefer to delegate
# back to each application for organization purposes.
#
# NOTE: import_config only expands wildcards on file extensions,
# so each child app's config is listed explicitly.
import_config "../apps/auction/config/config.exs"
import_config "../apps/auction_web/config/config.exs"

config :phoenix, :json_library, Jason

# Sample configuration (overrides the imported configuration above):
#
#     config :logger, :console,
#       level: :info,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
