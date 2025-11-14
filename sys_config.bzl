"""Public API for sys_config generation.

The elixir_sys_config rule generates Erlang sys.config files with support for:
- Compile-time configuration from config/*.exs files (via eval_config)
- Runtime configuration with Config.Provider support
- Automatic inference of environment, version, and paths
- Integration with Elixir releases

This rule bridges Elixir's Config system with OTP's sys.config format.
"""

load("//private:elixir_sys_config.bzl", _elixir_sys_config = "elixir_sys_config")

# Re-export the rule for public use
elixir_sys_config = _elixir_sys_config
