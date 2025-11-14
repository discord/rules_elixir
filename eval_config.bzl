"""Public API for eval_config rule.

This module provides the public interface for evaluating ALL Elixir application
configurations from config/*.exs files.
"""

load(
    "//private:eval_config.bzl",
    _eval_config = "eval_config",
)

# Re-export the rule for public use
eval_config = _eval_config