import Config

# Development-specific configuration
config :elixir_release_demo,
  production_mode: false,
  compile_time_env: :dev,
  debug: true

# Configure logger for development
config :logger,
  level: :debug