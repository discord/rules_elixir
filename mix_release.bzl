"""Public API for mix_release rule.

The mix_release rule creates an Elixir release by invoking Mix's release functionality
directly. This is the older approach that wraps Mix.

For new projects, consider using elixir_release from release.bzl instead, which
provides better integration with rules_erlang and more Bazel-native behavior.
"""

load("//private:mix_release.bzl", _mix_release = "mix_release")

# Re-export the rule for public use
mix_release = _mix_release
