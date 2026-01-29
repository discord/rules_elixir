"""Elixir integration testing with rules_itest services.

This module provides the `mix_service_test` macro for running ExUnit tests
that depend on external services managed by rules_itest.

Example usage:

```python
load("@rules_elixir//:mix_library.bzl", "mix_library")
load("@rules_elixir//:mix_service_test.bzl", "mix_service_test")

mix_library(
    name = "my_app_test_lib",
    app_name = "my_app",
    mix_env = "test",
    srcs = glob(["lib/**/*.ex"]),
    deps = [
        # Include the itest helper library for accessing service ports
        "@@//bazel/itest/elixir_itest_helpers",
    ],
)

# Integration test with etcd service
mix_service_test(
    name = "integration_test",
    lib = ":my_app_test_lib",
    srcs = glob(["test/integration/**/*_test.exs"]),
    services = [
        "@@//bazel/itest/etcd:etcd",
    ],
)
```

To access service ports in your Elixir tests, use the ITest helper module:

```elixir
defmodule MyIntegrationTest do
  use ExUnit.Case

  test "connects to etcd" do
    # Use the convenience function for etcd:
    port = ITest.Etcd.get_port!()

    # Or use the generic function with full target:
    port = ITest.get_port!("@@//bazel/itest/etcd:etcd")

    # Connect to etcd at localhost:port
  end
end
```
"""

load("@rules_itest//:itest.bzl", "service_test")
load("//private:mix_test.bzl", "mix_test")

def mix_service_test(
        name,
        lib,
        services,
        srcs = None,
        tools = [],
        env = {},
        setup = "",
        mix_test_opts = [],
        timeout = "long",
        size = "large",
        tags = [],
        visibility = None,
        **kwargs):
    """Run ExUnit tests with dependent services managed by rules_itest.

    This macro creates two targets:
    1. {name}_impl - The actual mix_test target (tagged as manual)
    2. {name} - A service_test wrapper that starts services before running tests

    Services are started by rules_itest and their ports are available via the
    ASSIGNED_PORTS environment variable. Use the ITest Elixir helper module
    to read the assigned ports in your test code.

    Args:
        name: Target name for this test
        lib: A mix_library target compiled with mix_env="test"
        services: List of itest_service targets to start before tests.
            Services are started and health-checked by rules_itest.
        srcs: Test source files (.exs). If empty, all tests are run.
        tools: Additional tools needed for tests
        env: Additional environment variables
        setup: Shell commands to run before tests
        mix_test_opts: Additional options passed to `mix test`
        timeout: Test timeout (default: "long" due to service startup time)
        size: Test size (default: "large" for integration tests)
        tags: Test tags
        visibility: Standard Bazel visibility
        **kwargs: Additional arguments passed to the underlying rule
    """
    impl_name = name + "_impl"

    # Ensure the impl target is tagged as manual so it's not run directly
    impl_tags = list(tags)
    if "manual" not in impl_tags:
        impl_tags.append("manual")

    # Create the actual mix_test target
    mix_test(
        name = impl_name,
        lib = lib,
        srcs = srcs,
        tools = tools,
        env = env,
        setup = setup,
        mix_test_opts = mix_test_opts,
        timeout = timeout,
        size = size,
        tags = impl_tags,
        visibility = ["//visibility:private"],
        **kwargs
    )

    # Wrap with service_test
    service_test_tags = list(tags)
    if "integration" not in service_test_tags:
        service_test_tags.append("integration")

    service_test(
        name = name,
        test = ":" + impl_name,
        services = services,
        env = env,
        tags = service_test_tags,
        visibility = visibility,
    )
