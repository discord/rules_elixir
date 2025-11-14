# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
import Config

# Configure the application
config :elixir_release_demo,
  compile_time_value: "This was set at compile time",
  environment: config_env()

# Configure logging
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"