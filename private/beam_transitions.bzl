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

When both flags are empty, --platforms passes through unchanged: BEAM then
still compiles once per target platform, but always with the toolchain the
target platform selects. Clearing it to [] would fall back to the host
platform, which drops the target's erlang/elixir version constraints.

It always sets //:beam_only, which `mix_library` uses to drop its
platform-dependent edges in this config. See `mix_library` in
private/mix_library.bzl.
"""

# Cross-repo reference needs Label() for canonicalization. The str() result
# is used as both the inputs entry and the settings dict key.
_ERLANG_PLATFORM_LABEL = str(Label("@rules_erlang//:erlang_platform"))

def _platform_independent_impl(settings, attr):
    platforms = settings["//command_line_option:platforms"]
    if settings["//:elixir_platform"]:
        platforms = [settings["//:elixir_platform"]]
    elif settings[_ERLANG_PLATFORM_LABEL]:
        platforms = [settings[_ERLANG_PLATFORM_LABEL]]

    return {
        "//command_line_option:platforms": platforms,
        "//:beam_only": True,
    }

# IMPORTANT: everything under this transition is analyzed with a platform
# that may have no OS/CPU constraints. Any platform-dependent edge reachable
# from _mix_compile (native priv today) must be select()ed away on
# //:beam_only_enabled in `mix_library`, or toolchain resolution for it fails
# (rules_rust: "No matching toolchains found").
platform_independent_transition = transition(
    implementation = _platform_independent_impl,
    inputs = [
        "//command_line_option:platforms",
        "//:elixir_platform",
        _ERLANG_PLATFORM_LABEL,
    ],
    outputs = [
        "//command_line_option:platforms",
        "//:beam_only",
    ],
)
