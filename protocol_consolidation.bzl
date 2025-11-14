"""Public API for protocol consolidation.

This module provides the public interface for consolidating Elixir protocols
to improve runtime performance by pre-computing protocol dispatch.
"""

load(
    "//private:protocol_consolidation.bzl",
    _consolidate_protocols_for_release = "consolidate_protocols_for_release",
    _elixir_protocol_consolidation = "elixir_protocol_consolidation",
)

# Re-export the rules for public use
elixir_protocol_consolidation = _elixir_protocol_consolidation
consolidate_protocols_for_release = _consolidate_protocols_for_release