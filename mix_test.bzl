load(
    "//private:mix_test.bzl",
    _mix_test = "mix_test",
)

def mix_test(**kwargs):
    """Run mix test on an Elixir project.

    This rule runs `mix test` on a Mix project, executing the project's test suite.

    Args:
        name: The name of the test target
        mix_config: The mix.exs configuration file (default: ":mix.exs")
        srcs: Optional list of specific test files to run. If empty, runs all tests in test/
        data: Additional data files needed for tests
        deps: Dependencies required for the tests (must provide ErlangAppInfo)
        ez_deps: Erlang/Elixir archive dependencies (.ez files)
        tools: Additional tools needed for tests
        env: Environment variables to set during test execution
        setup: Shell commands to run before executing tests
        mix_test_opts: Additional options to pass to 'mix test' (e.g., ["--trace", "--seed", "0"])
        **kwargs: Additional arguments passed to the underlying test rule

    Example:
        ```python
        mix_test(
            name = "my_project_test",
            mix_config = "mix.exs",
            deps = [":my_app"],
            env = {
                "MIX_ENV": "test",
            },
            mix_test_opts = ["--trace"],
        )
        ```
    """
    _mix_test(**kwargs)
