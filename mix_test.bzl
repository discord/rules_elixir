load(
    "//private:mix_test.bzl",
    _mix_test = "mix_test",
)

def mix_test(name, lib, **kwargs):
    """Run mix test using pre-compiled artifacts from a mix_library.

    This rule runs `mix test` on a Mix project using pre-compiled artifacts
    from a mix_library target. The library must be compiled with mix_env="test".

    Args:
        name: The name of the test target
        lib: The mix_library target containing the compiled application.
             Must be compiled with mix_env="test".
        srcs: Optional list of specific test files to run. If empty, runs all tests in test/
        data: Additional data files needed for tests (include test/**/*.exs here)
        ez_deps: Erlang/Elixir archive dependencies (.ez files)
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
            data = glob(["test/**/*.exs"]),
            mix_test_opts = ["--trace"],
        )
        ```
    """
    _mix_test(name = name, lib = lib, **kwargs)
