"""Configuration transitions for platform-independent BEAM compilation.

BEAM bytecode (.beam) and .app files are platform-independent artifacts.
This transition normalizes platform-related settings so that compilation
actions get the same configuration hash regardless of target platform,
enabling remote cache hits across platforms.
"""

def _platform_independent_impl(settings, attr):
    return {"//command_line_option:platforms": []}

platform_independent_transition = transition(
    implementation = _platform_independent_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = ["//command_line_option:platforms"],
)
