"""Public API for creating deployable Elixir release bundles.

The elixir_release_bundle rule takes an elixir_release and creates a complete,
deployable OTP release bundle with:
- Standard OTP directory structure (bin/, lib/, releases/, erts/)
- Startup scripts with multiple modes (start, console, foreground)
- Optional ERTS inclusion for self-contained deployments
- Consolidated protocols and runtime configuration support
- All application dependencies and private resources

The resulting bundle can be copied to a target system and run directly.
"""

load("//private:elixir_release_bundle.bzl", _elixir_release_bundle = "elixir_release_bundle")

# Re-export the rule for public use
elixir_release_bundle = _elixir_release_bundle
