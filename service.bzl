"""Public API for defining services for integration testing.

This module provides the `itest_service` macro for defining services that can be
started as dependencies for integration tests.

Example usage:

```python
load("@discord_rules_elixir//:service.bzl", "itest_service")

itest_service(
    name = "etcd",
    command = "etcd --enable-v2 -data-dir=$HOME/var/etcd",
    ports = [{"port": "2379", "protocol": "TCP"}],
    health_check = {
        "type": "http",
        "route": "/health",
        "port": "2379",
        "max_seconds": "100",
    },
)
```
"""

load("//private:service.bzl", _itest_service = "itest_service")
load("//private:service_info.bzl", _ServiceInfo = "ServiceInfo")

# Re-export for external use
ServiceInfo = _ServiceInfo

def itest_service(
        name,
        command,
        ports = [],
        health_check = None,
        deps = [],
        env = {},
        data = [],
        stop_wait_seconds = 5,
        working_dir = None,
        visibility = None,
        **kwargs):
    """Define a service for integration testing.

    This macro creates a service target that can be used as a dependency for
    integration tests. Services are started in dependency order and health
    checks are verified before tests run.

    Args:
        name: Target name for this service
        command: Shell command to start the service. The command should run
            in the foreground (not daemonize).
        ports: List of port specifications. Each entry is a dict with:
            - "port": Port number (string or int)
            - "protocol": Optional, "TCP" (default) or "UDP"
        health_check: Optional health check configuration dict:
            - HTTP check: {"type": "http", "route": "/health", "port": "8080", "max_seconds": "60"}
            - Command check: {"type": "command", "command": "curl localhost:8080", "max_seconds": "60"}
        deps: List of other itest_service targets this service depends on.
            Dependencies are started first.
        env: Dict of environment variables to set when running the service.
        data: Data files needed at runtime.
        stop_wait_seconds: Grace period before force-killing (default: 5)
        working_dir: Working directory for the service command
        visibility: Standard Bazel visibility
        **kwargs: Additional arguments passed to the underlying rule
    """

    # Normalize ports to "port:protocol" format
    normalized_ports = []
    for port_spec in ports:
        if type(port_spec) == "dict":
            port_num = str(port_spec.get("port", ""))
            protocol = port_spec.get("protocol", "TCP")
            normalized_ports.append("{}:{}".format(port_num, protocol))
        else:
            # Assume it's just a port number
            normalized_ports.append("{}:TCP".format(port_spec))

    # Convert health_check values to strings for Bazel string_dict
    normalized_health_check = None
    if health_check:
        normalized_health_check = {k: str(v) for k, v in health_check.items()}

    _itest_service(
        name = name,
        command = command,
        ports = normalized_ports,
        health_check = normalized_health_check,
        deps = deps,
        env = env,
        data = data,
        stop_wait_seconds = stop_wait_seconds,
        working_dir = working_dir,
        visibility = visibility,
        **kwargs
    )

def itest_service_group(
        name,
        services,
        visibility = None):
    """Create a group of services that can be referenced together.

    This is a convenience macro that creates a filegroup containing multiple
    services, allowing them to be referenced as a single target.

    Args:
        name: Target name for this service group
        services: List of itest_service targets to include in this group
        visibility: Standard Bazel visibility
    """
    native.filegroup(
        name = name,
        srcs = services,
        visibility = visibility,
    )
