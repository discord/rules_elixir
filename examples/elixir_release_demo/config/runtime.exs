import Config

# This file is evaluated at runtime by Config.Provider
# It can access environment variables and other runtime information

# Read configuration from environment variables
if System.get_env("DEMO_RUNTIME_VALUE") do
  config :elixir_release_demo,
    runtime_value: System.get_env("DEMO_RUNTIME_VALUE")
end

# Configure based on runtime environment
if config_env() == :prod do
  # Production runtime configuration
  config :elixir_release_demo,
    runtime_mode: :production,
    runtime_timestamp: DateTime.utc_now()

  # Adjust logger based on LOG_LEVEL env var
  if log_level = System.get_env("LOG_LEVEL") do
    config :logger, level: String.to_atom(log_level)
  end
else
  # Development/test runtime configuration
  config :elixir_release_demo,
    runtime_mode: :development,
    runtime_timestamp: DateTime.utc_now()
end