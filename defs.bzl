load("//private:mix_library.bzl", _mix_library = "mix_library")
load("//private:mix_release.bzl", _mix_release = "mix_release")
load("//private:mix_test.bzl", _mix_test = "mix_test")
load("//private:elixir_app.bzl", _elixir_app = "elixir_app")
load(
    "//private:ex_unit_test.bzl",
    _ex_unit_test = "ex_unit_test",
)

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

def ex_unit_test(**kwargs):
    _ex_unit_test(
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )

def elixir_app(**kwargs):
    _elixir_app(**kwargs)
