import Config

# Test-specific configuration
config :elixir_release_demo,
  production_mode: false,
  compile_time_env: :test,
  testing: true

# Configure logger for tests (reduce noise)
config :logger,
  level: :warning