"Provider definitions for integration test services."

# Health check type constants
HEALTH_CHECK_TYPE_HTTP = "http"
HEALTH_CHECK_TYPE_COMMAND = "command"

ServiceInfo = provider(
    doc = "Information about a service for integration testing",
    fields = {
        "name": "Service name (string)",
        "command": "Shell command to start the service (string)",
        "ports": "List of port specifications, each a struct with 'port' (int) and 'protocol' (string, TCP/UDP)",
        "health_check_type": "Type of health check: 'http' or 'command' (string, or None)",
        "health_check_route": "HTTP route for health check (string, only for http type)",
        "health_check_port": "Port for HTTP health check (int, only for http type)",
        "health_check_command": "Shell command for health check (string, only for command type)",
        "health_check_max_seconds": "Maximum seconds to wait for health check (int)",
        "dependencies": "depset of ServiceInfo providers this service depends on",
        "env": "Dict of environment variables to set when running service",
        "data_runfiles": "Runfiles needed by this service",
        "stop_wait_seconds": "Grace period in seconds before force killing (int)",
        "working_dir": "Working directory for the command (string, or None)",
        "launch_script": "Generated launch script file (File)",
    },
)

def create_port_struct(port, protocol = "TCP"):
    """Create a port specification struct.

    Args:
        port: Port number (int)
        protocol: Protocol type, "TCP" or "UDP" (default: "TCP")

    Returns:
        A struct with port and protocol fields
    """
    if protocol not in ["TCP", "UDP"]:
        fail("Protocol must be 'TCP' or 'UDP', got: " + protocol)
    return struct(port = port, protocol = protocol)

def validate_health_check(health_check):
    """Validate a health check configuration dict.

    Args:
        health_check: Dict with health check configuration, or None

    Returns:
        Validated health check dict, or None
    """
    if health_check == None:
        return None

    if "type" not in health_check:
        fail("health_check must have a 'type' field")

    check_type = health_check["type"]
    if check_type not in [HEALTH_CHECK_TYPE_HTTP, HEALTH_CHECK_TYPE_COMMAND]:
        fail("health_check type must be '{}' or '{}', got: {}".format(
            HEALTH_CHECK_TYPE_HTTP, HEALTH_CHECK_TYPE_COMMAND, check_type))

    if check_type == HEALTH_CHECK_TYPE_HTTP:
        if "port" not in health_check:
            fail("HTTP health_check must have a 'port' field")
        if "route" not in health_check:
            fail("HTTP health_check must have a 'route' field")
    elif check_type == HEALTH_CHECK_TYPE_COMMAND:
        if "command" not in health_check:
            fail("Command health_check must have a 'command' field")

    return health_check

def topological_sort_services(services):
    """Topologically sort services by their dependencies.

    Args:
        services: List of ServiceInfo providers

    Returns:
        List of ServiceInfo providers in dependency order (dependencies first)
    """
    if not services:
        return []

    # Build adjacency map and in-degree count
    service_map = {s.name: s for s in services}
    in_degree = {s.name: 0 for s in services}
    dependents = {s.name: [] for s in services}

    for service in services:
        for dep in service.dependencies.to_list():
            if dep.name in service_map:
                in_degree[service.name] = in_degree[service.name] + 1
                dependents[dep.name] = dependents[dep.name] + [service.name]

    # Kahn's algorithm using for loop (Starlark doesn't support while)
    # We know max iterations is len(services)
    result = []
    queue = [name for name, degree in in_degree.items() if degree == 0]

    for _ in range(len(services)):
        if not queue:
            break
        name = queue[0]
        queue = queue[1:]  # pop first element
        result.append(service_map[name])
        for dependent_name in dependents[name]:
            in_degree[dependent_name] = in_degree[dependent_name] - 1
            if in_degree[dependent_name] == 0:
                queue = queue + [dependent_name]

    if len(result) != len(services):
        fail("Circular dependency detected in services")

    return result
