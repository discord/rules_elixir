"""Configuration transitions for platform-independent BEAM compilation.

BEAM bytecode (.beam) and .app files are platform-independent artifacts.
This transition normalizes platform-related settings so that compilation
actions get the same configuration hash regardless of target platform,
enabling remote cache hits across platforms.

When //:elixir_platform is set, the transition uses that platform (which
should carry both elixir_version and erlang_version constraints) for
correct toolchain resolution with multiple versions.

Falls back to @rules_erlang//:erlang_platform if only the Erlang flag
is set (covers transitive Erlang rule usage).

When both flags are empty (default), --platforms is cleared to [] —
identical to the previous behavior, safe for single-version setups.
"""

# Cross-repo reference needs Label() for canonicalization. The str() result
# is used as both the inputs entry and the settings dict key.
_ERLANG_PLATFORM_LABEL = str(Label("@rules_erlang//:erlang_platform"))

def _platform_independent_impl(settings, attr):
    elixir_platform = settings["//:elixir_platform"]
    if elixir_platform:
        return {"//command_line_option:platforms": [elixir_platform]}

    erlang_platform = settings[_ERLANG_PLATFORM_LABEL]
    if erlang_platform:
        return {"//command_line_option:platforms": [erlang_platform]}

    return {"//command_line_option:platforms": []}

platform_independent_transition = transition(
    implementation = _platform_independent_impl,
    inputs = [
        "//command_line_option:platforms",
        "//:elixir_platform",
        _ERLANG_PLATFORM_LABEL,
    ],
    outputs = ["//command_line_option:platforms"],
)
