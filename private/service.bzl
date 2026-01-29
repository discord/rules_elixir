"Private implementation of the itest_service rule."

load("@bazel_skylib//lib:shell.bzl", "shell")
load(
    "//private:service_info.bzl",
    "HEALTH_CHECK_TYPE_COMMAND",
    "HEALTH_CHECK_TYPE_HTTP",
    "ServiceInfo",
    "create_port_struct",
    "validate_health_check",
)

def _parse_port_spec(port_spec):
    """Parse a port specification string like '2379:TCP' or '2379'.

    Args:
        port_spec: String in format 'port' or 'port:protocol'

    Returns:
        Tuple of (port_number, protocol)
    """
    if ":" in port_spec:
        parts = port_spec.split(":")
        return (int(parts[0]), parts[1])
    else:
        return (int(port_spec), "TCP")

def _itest_service_impl(ctx):
    """Implementation of the itest_service rule."""

    # Validate and process health check
    health_check = validate_health_check(ctx.attr.health_check)

    # Process ports - format is "port:protocol" or just "port"
    ports = []
    for port_spec in ctx.attr.ports:
        port_num, protocol = _parse_port_spec(port_spec)
        ports.append(create_port_struct(port_num, protocol))

    # Collect dependencies
    dep_infos = []
    for dep in ctx.attr.deps:
        if ServiceInfo in dep:
            dep_infos.append(dep[ServiceInfo])

    dependencies = depset(
        direct = dep_infos,
        transitive = [d.dependencies for d in dep_infos],
    )

    # Generate launch script for this service
    launch_script = ctx.actions.declare_file(ctx.label.name + "_launch.sh")

    # Build environment exports
    env_exports = "\n".join([
        "export {}={}".format(k, shell.quote(v))
        for k, v in ctx.attr.env.items()
    ])

    # Determine working directory setup
    working_dir = ctx.attr.working_dir if ctx.attr.working_dir else ""
    working_dir_cmd = ""
    if working_dir:
        working_dir_cmd = 'cd "{}"'.format(working_dir)

    script_content = """\
#!/usr/bin/env bash
set -eo pipefail

# Service: {name}
# Generated launch script

{env_exports}

{working_dir_cmd}

# Execute the service command
exec {command}
""".format(
        name = ctx.label.name,
        env_exports = env_exports,
        working_dir_cmd = working_dir_cmd,
        command = ctx.attr.command,
    )

    ctx.actions.write(
        output = launch_script,
        content = script_content,
        is_executable = True,
    )

    # Collect runfiles from data dependencies
    runfiles = ctx.runfiles(files = ctx.files.data + [launch_script])
    for data_dep in ctx.attr.data:
        if DefaultInfo in data_dep:
            runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    # Extract health check fields
    health_check_type = None
    health_check_route = ""
    health_check_port = 0
    health_check_command = ""
    health_check_max_seconds = 60

    if health_check:
        health_check_type = health_check["type"]
        max_seconds_str = health_check.get("max_seconds", "60")
        health_check_max_seconds = int(max_seconds_str) if max_seconds_str else 60
        if health_check_type == HEALTH_CHECK_TYPE_HTTP:
            health_check_route = health_check.get("route", "/health")
            port_str = health_check.get("port", "0")
            health_check_port = int(port_str) if port_str else 0
        elif health_check_type == HEALTH_CHECK_TYPE_COMMAND:
            health_check_command = health_check.get("command", "")

    return [
        DefaultInfo(
            files = depset([launch_script]),
            runfiles = runfiles,
            executable = launch_script,
        ),
        ServiceInfo(
            name = ctx.label.name,
            command = ctx.attr.command,
            ports = ports,
            health_check_type = health_check_type,
            health_check_route = health_check_route,
            health_check_port = health_check_port,
            health_check_command = health_check_command,
            health_check_max_seconds = health_check_max_seconds,
            dependencies = dependencies,
            env = ctx.attr.env,
            data_runfiles = runfiles,
            stop_wait_seconds = ctx.attr.stop_wait_seconds,
            working_dir = ctx.attr.working_dir,
            launch_script = launch_script,
        ),
    ]

itest_service = rule(
    implementation = _itest_service_impl,
    attrs = {
        "command": attr.string(
            mandatory = True,
            doc = "Shell command to start the service",
        ),
        "ports": attr.string_list(
            doc = "List of port specifications. Each entry is 'port' or 'port:protocol' (e.g., '2379' or '2379:TCP')",
        ),
        "health_check": attr.string_dict(
            doc = """Health check configuration. Supported types:
            - HTTP: {"type": "http", "route": "/health", "port": 8080, "max_seconds": 60}
            - Command: {"type": "command", "command": "curl localhost:8080", "max_seconds": 60}
            """,
        ),
        "deps": attr.label_list(
            providers = [ServiceInfo],
            doc = "Other services this service depends on (will be started first)",
        ),
        "env": attr.string_dict(
            doc = "Environment variables to set when running the service",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Data files needed at runtime",
        ),
        "stop_wait_seconds": attr.int(
            default = 5,
            doc = "Grace period in seconds before force killing the service",
        ),
        "working_dir": attr.string(
            doc = "Working directory for the service command",
        ),
    },
    executable = True,
)
