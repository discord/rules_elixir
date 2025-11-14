"""Public API for Elixir releases.

The elixir_release rule creates an OTP release with Elixir-specific features:
- Wraps erlang_release from rules_erlang for base OTP release generation
- Post-processes boot scripts to inject Config.Provider support
- Adds consolidated protocol paths for performance optimization
- Maintains full compatibility with mixed Erlang/Elixir projects

This is the recommended approach for creating Elixir releases in Bazel.
"""

load("//private:elixir_release.bzl", _elixir_release = "elixir_release")

# Re-export the rule for public use
elixir_release = _elixir_release
