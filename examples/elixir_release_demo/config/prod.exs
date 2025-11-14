import Config

# Production-specific configuration
config :elixir_release_demo,
  production_mode: true,
  compile_time_env: :prod

# Configure logger for production
config :logger,
  level: :warning