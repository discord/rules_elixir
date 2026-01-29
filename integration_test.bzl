"""Public API for Elixir integration testing with services.

This module provides the `mix_integration_test` macro for running ExUnit tests
that depend on external services (etcd, scylla, confy, etc.).

Example usage:

```python
load("@discord_rules_elixir//:mix_library.bzl", "mix_library")
load("@discord_rules_elixir//:integration_test.bzl", "mix_integration_test")

# Compile the library for testing
mix_library(
    name = "my_app_test_lib",
    app_name = "my_app",
    mix_env = "test",
    srcs = glob(["lib/**/*.ex"]),
    deps = [...],
)

# Run integration tests with services
mix_integration_test(
    name = "integration_tests",
    lib = ":my_app_test_lib",
    srcs = glob(["test/integration/**/*_test.exs"]),
    services = [
        "@discord_rules_elixir//services:etcd",
        "@discord_rules_elixir//services:scylla",
    ],
    env = {
        "ETCD_URL": "http://localhost:2379",
    },
    tags = ["integration"],
)
```
"""

load("//private:integration_test.bzl", _mix_integration_test = "mix_integration_test")
load("//private:service_info.bzl", _ServiceInfo = "ServiceInfo")

# Re-export ServiceInfo for external use
ServiceInfo = _ServiceInfo

def mix_integration_test(
        name,
        lib,
        services = [],
        srcs = None,
        data = [],
        tools = [],
        env = {},
        setup = "",
        mix_test_opts = [],
        timeout = "long",
        size = "large",
        tags = [],
        visibility = None,
        **kwargs):
    """Run ExUnit integration tests with dependent services.

    This macro creates a test target that:
    1. Starts services in dependency order
    2. Waits for each service's health check to pass
    3. Exports service endpoints as environment variables
    4. Runs the ExUnit tests
    5. Cleans up services (even on test failure)

    Services are started with the following environment variable convention:
    - {SERVICE_NAME}_HOST: Always "localhost"
    - {SERVICE_NAME}_PORT: The primary port of the service
    - {SERVICE_NAME}_URL: "http://localhost:{port}" for HTTP services

    Args:
        name: Target name for this test
        lib: A mix_library target compiled with mix_env="test"
        services: List of itest_service targets to start before tests.
            Services are started in dependency order.
        srcs: Test source files (.exs). If empty, all tests are run.
        data: Additional data files needed for tests
        tools: Additional tools needed for tests
        env: Additional environment variables (can override service defaults)
        setup: Shell commands to run before tests (after services are started)
        mix_test_opts: Additional options passed to `mix test`
        timeout: Test timeout (default: "long" due to service startup time)
        size: Test size (default: "large" for integration tests)
        tags: Test tags (consider adding "integration" for filtering)
        visibility: Standard Bazel visibility
        **kwargs: Additional arguments passed to the underlying rule
    """

    # Add integration tag if not present
    all_tags = list(tags)
    if "integration" not in all_tags:
        all_tags.append("integration")

    _mix_integration_test(
        name = name,
        lib = lib,
        services = services,
        srcs = srcs,
        data = data,
        tools = tools,
        env = env,
        setup = setup,
        mix_test_opts = mix_test_opts,
        timeout = timeout,
        size = size,
        tags = all_tags,
        visibility = visibility,
        **kwargs
    )
