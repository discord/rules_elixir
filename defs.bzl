load("//private:mix_library.bzl", _mix_library = "mix_library")
load("//private:mix_release.bzl", _mix_release = "mix_release")
load("//private:mix_test.bzl", _mix_test = "mix_test")
load("//private:elixir_app.bzl", _elixir_app = "elixir_app")
load(
    "//private:ex_unit_test.bzl",
    _ex_unit_test = "ex_unit_test",
)
load(
    "//private:elixir_build.bzl",
    _elixir_build = "elixir_build",
    _elixir_external = "elixir_external",
)
load("//private:elixir_release.bzl", _elixir_release = "elixir_release")
load("//private:elixir_release_bundle.bzl", _elixir_release_bundle = "elixir_release_bundle")
load(
    "//private:elixir_toolchain.bzl",
    _elixir_toolchain = "elixir_toolchain",
)
load(
    "//private:iex_eval.bzl",
    _iex_eval = "iex_eval",
)
load(
    "//private:protocol_consolidation.bzl",
    _consolidate_protocols_for_release = "consolidate_protocols_for_release",
    _elixir_protocol_consolidation = "elixir_protocol_consolidation",
)
load(
    "//private:eval_config.bzl",
    _eval_config = "eval_config",
)
load("//private:elixir_sys_config.bzl", _elixir_sys_config = "elixir_sys_config")

# mix-backed targets. Generally fairly reliable, and set-and-forget.
def mix_library(*args, **kwargs):
    """Compiles an Elixir library using Mix.

    Automatically adds dependencies for hex unless the app_name is "hex",
    because hex is required for mix to evaluate if a dev/runtime/test/etc
    dependency is relevant in the current compilation context (even though
    we invoke in offline mode)
    """
    deps = kwargs.pop("deps", [])
    if kwargs.get("app_name") != "hex":
        deps.append(Label("@hex_pm//:lib"))
    kwargs['deps'] = deps
    _mix_library(*args, **kwargs)

def mix_release(*args, **kwargs):
    _mix_release(*args, **kwargs)

def mix_test(name, lib, srcs = None, **kwargs):
    """Run mix test using pre-compiled artifacts from a mix_library.

    This rule runs `mix test` on a Mix project using pre-compiled artifacts
    from a mix_library target. The library must be compiled with mix_env="test".

    Args:
        name: The name of the test target
        lib: The mix_library target containing the compiled application.
             Must be compiled with mix_env="test".
        srcs: Optional list of specific test files to run. If empty, runs all tests in test/
        tools: Additional tools needed for tests
        env: Environment variables to set during test execution
        setup: Shell commands to run before executing tests
        mix_test_opts: Additional options to pass to 'mix test' (e.g., ["--trace", "--seed", "0"])
        **kwargs: Additional arguments passed to the underlying test rule

    Example:
        ```python
        # First, create a test library compiled with MIX_ENV=test
        mix_library(
            name = "my_app_test_lib",
            app_name = "my_app",
            mix_env = "test",
            srcs = glob(["lib/**/*.ex"]),
        )

        # Then create the test target
        mix_test(
            name = "my_app_test",
            lib = ":my_app_test_lib",
            srcs = glob(["test/**/*.exs"]),
            mix_test_opts = ["--trace"],
        )
        ```
    """
    # Validate test files exist if srcs not provided
    if srcs == None or len(srcs) == 0:
        test_files = native.glob(["test/**/*_test.exs"])
        if len(test_files) == 0:
            fail("mix_test '{}' has no tests to run. ".format(name) +
                 "No files matching test/**/*_test.exs were found and no srcs were provided.")

    _mix_test(name = name, lib = lib, srcs = srcs, **kwargs)

# elixirc-backed targets. Generally sane, but are generally more fragile/prone
# to requiring specifically-crafted BUILD files.
# These will generally be faster than using their mix-equivalent counterparts,
# but also do not support niceties like compile-time plugins
def elixir_app(**kwargs):
    return _elixir_app(**kwargs)

def elixir_build(**kwargs):
    return _elixir_build(**kwargs)

def elixir_release(**kwargs):
    return _elixir_release(**kwargs)

def elixir_release_bundle(**kwargs):
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
    return _elixir_release_bundle(**kwargs)

# Mixless unit test target
def ex_unit_test(**kwargs):
    _ex_unit_test(
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )

# Targets for building and utilising elixir toolchains
def elixir_external(**kwargs):
    return _elixir_external(**kwargs)

def elixir_toolchain(**kwargs):
    return _elixir_toolchain(**kwargs)

def iex_eval(**kwargs):
    return _iex_eval(**kwargs)

# Stdlib-only backed implementation of protocol consolidation. Redundant if
# compiling with mix-backed targets.
def elixir_protocol_consolidation(**kwargs):
    return _elixir_protocol_consolidation(**kwargs)

# Convenience macro for the above
def consolidate_protocols_for_release(**kwargs):
    return _consolidate_protocols_for_release(**kwargs)

# Stdlib-only compilation of elixir configs
def eval_config(**kwargs):
    _eval_config(**kwargs)

def elixir_sys_config(**kwargs):
    """Public API for sys_config generation.

    The elixir_sys_config rule generates Erlang sys.config files with support for:
    - Compile-time configuration from config/*.exs files (via eval_config)
    - Runtime configuration with Config.Provider support
    - Automatic inference of environment, version, and paths
    - Integration with Elixir releases

    This rule bridges Elixir's Config system with OTP's sys.config format.
    """
    _elixir_sys_config(**kwargs)
