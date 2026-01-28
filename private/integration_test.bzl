"Private implementation of the mix_integration_test rule."

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)
load("//private:mix_info.bzl", "MixProjectInfo")
load(
    "//private:service_info.bzl",
    "HEALTH_CHECK_TYPE_COMMAND",
    "HEALTH_CHECK_TYPE_HTTP",
    "ServiceInfo",
    "topological_sort_services",
)

def _collect_services(ctx):
    """Collect all ServiceInfo providers from services attribute."""
    services = []
    for svc in ctx.attr.services:
        if ServiceInfo in svc:
            services.append(svc[ServiceInfo])
    return services

def _generate_service_orchestration(services):
    """Generate shell script code for service orchestration.

    Args:
        services: List of ServiceInfo providers (already topologically sorted)

    Returns:
        Tuple of (setup_code, cleanup_code, env_exports)
    """
    if not services:
        return ("", "", "")

    # Generate service arrays and configuration
    service_names = [s.name for s in services]
    service_names_str = " ".join(['"{}"'.format(n) for n in service_names])

    # Build service configuration arrays
    config_lines = []
    config_lines.append("# Service configuration")
    config_lines.append("declare -A SERVICE_COMMANDS")
    config_lines.append("declare -A SERVICE_PIDS")
    config_lines.append("declare -A SERVICE_HEALTH_TYPE")
    config_lines.append("declare -A SERVICE_HEALTH_ROUTE")
    config_lines.append("declare -A SERVICE_HEALTH_PORT")
    config_lines.append("declare -A SERVICE_HEALTH_CMD")
    config_lines.append("declare -A SERVICE_MAX_WAIT")
    config_lines.append("declare -A SERVICE_STOP_WAIT")
    config_lines.append('SERVICE_ORDER=({})'.format(service_names_str))
    config_lines.append("")

    for svc in services:
        name = svc.name
        config_lines.append('SERVICE_COMMANDS["{}"]={}'.format(name, shell.quote(svc.command)))
        config_lines.append('SERVICE_MAX_WAIT["{}"]={}'.format(name, svc.health_check_max_seconds))
        config_lines.append('SERVICE_STOP_WAIT["{}"]={}'.format(name, svc.stop_wait_seconds))

        if svc.health_check_type:
            config_lines.append('SERVICE_HEALTH_TYPE["{}"]={}'.format(name, shell.quote(svc.health_check_type)))
            if svc.health_check_type == HEALTH_CHECK_TYPE_HTTP:
                config_lines.append('SERVICE_HEALTH_ROUTE["{}"]={}'.format(name, shell.quote(svc.health_check_route)))
                config_lines.append('SERVICE_HEALTH_PORT["{}"]={}'.format(name, svc.health_check_port))
            elif svc.health_check_type == HEALTH_CHECK_TYPE_COMMAND:
                config_lines.append('SERVICE_HEALTH_CMD["{}"]={}'.format(name, shell.quote(svc.health_check_command)))
        config_lines.append("")

    # Generate environment exports based on service ports
    env_exports_lines = []
    for svc in services:
        upper_name = svc.name.upper().replace("-", "_")
        env_exports_lines.append('export {}_HOST="localhost"'.format(upper_name))
        if svc.ports:
            primary_port = svc.ports[0].port
            env_exports_lines.append('export {}_PORT="{}"'.format(upper_name, primary_port))
            # For HTTP services, also export a URL
            if svc.health_check_type == HEALTH_CHECK_TYPE_HTTP:
                env_exports_lines.append('export {}_URL="http://localhost:{}"'.format(upper_name, primary_port))

    service_functions = '''
# === Service Functions ===

start_service() {
    local name="$1"
    local cmd="${SERVICE_COMMANDS[$name]}"

    echo "[itest] Starting service: $name"
    # Start in background, redirect output to log file
    local log_file="$TEST_TMPDIR/service_${name}.log"
    eval "$cmd" > "$log_file" 2>&1 &
    SERVICE_PIDS[$name]=$!
    echo "[itest] Service $name started with PID ${SERVICE_PIDS[$name]}"
}

wait_for_health() {
    local name="$1"
    local check_type="${SERVICE_HEALTH_TYPE[$name]:-}"
    local max_seconds="${SERVICE_MAX_WAIT[$name]:-60}"

    if [[ -z "$check_type" ]]; then
        echo "[itest] No health check for $name, waiting 1 second..."
        sleep 1
        return 0
    fi

    echo "[itest] Waiting for $name to become healthy (max ${max_seconds}s)..."
    local start_time=$(date +%s)

    while true; do
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $max_seconds ]]; then
            echo "[itest] ERROR: Health check timeout for $name after ${max_seconds}s"
            echo "[itest] Service log:"
            cat "$TEST_TMPDIR/service_${name}.log" 2>/dev/null || true
            return 1
        fi

        # Check if process is still running
        local pid="${SERVICE_PIDS[$name]:-}"
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            echo "[itest] ERROR: Service $name (PID $pid) died unexpectedly"
            echo "[itest] Service log:"
            cat "$TEST_TMPDIR/service_${name}.log" 2>/dev/null || true
            return 1
        fi

        if [[ "$check_type" == "http" ]]; then
            local port="${SERVICE_HEALTH_PORT[$name]}"
            local route="${SERVICE_HEALTH_ROUTE[$name]}"
            if curl -sf "http://localhost:${port}${route}" > /dev/null 2>&1; then
                echo "[itest] Service $name is healthy (HTTP check passed)"
                return 0
            fi
        elif [[ "$check_type" == "command" ]]; then
            local cmd="${SERVICE_HEALTH_CMD[$name]}"
            if eval "$cmd" > /dev/null 2>&1; then
                echo "[itest] Service $name is healthy (command check passed)"
                return 0
            fi
        fi

        sleep 0.5
    done
}

stop_service() {
    local name="$1"
    local pid="${SERVICE_PIDS[$name]:-}"
    local wait_seconds="${SERVICE_STOP_WAIT[$name]:-5}"

    if [[ -z "$pid" ]]; then
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "[itest] Service $name (PID $pid) already stopped"
        return 0
    fi

    echo "[itest] Stopping $name (PID $pid)..."
    kill -TERM "$pid" 2>/dev/null || true

    # Wait for graceful shutdown
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt $wait_seconds ]]; do
        sleep 1
        count=$((count + 1))
    done

    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        echo "[itest] Force killing $name (PID $pid)..."
        kill -9 "$pid" 2>/dev/null || true
    fi
}

stop_all_services() {
    echo "[itest] Stopping all services..."
    # Stop in reverse order
    for ((i=${#SERVICE_ORDER[@]}-1; i>=0; i--)); do
        local name="${SERVICE_ORDER[$i]}"
        stop_service "$name"
    done
}
'''

    # Generate startup code
    startup_code = '''
# === Start Services ===
echo "[itest] Starting services in dependency order..."
for name in "${SERVICE_ORDER[@]}"; do
    start_service "$name"
    if ! wait_for_health "$name"; then
        echo "[itest] Failed to start service $name"
        stop_all_services
        exit 1
    fi
done
echo "[itest] All services started successfully"
'''

    setup_code = "\n".join(config_lines) + service_functions + "\n# Set up cleanup trap\ntrap stop_all_services EXIT\n" + startup_code
    env_exports = "\n".join(env_exports_lines)

    return (setup_code, "", env_exports)

def _mix_integration_test_impl(ctx):
    """Implementation of the mix_integration_test rule."""

    # Get providers from the lib dependency
    lib_erlang_info = ctx.attr.lib[ErlangAppInfo]
    lib_mix_info = ctx.attr.lib[MixProjectInfo]

    # Validate that lib was compiled with mix_env="test"
    if lib_mix_info.mix_env != "test":
        fail("mix_integration_test requires a mix_library compiled with mix_env='test'. " +
             "Target '{}' was compiled with mix_env='{}'. ".format(ctx.attr.lib.label, lib_mix_info.mix_env) +
             "Create a separate mix_library with mix_env='test' for testing.")

    app_name = lib_erlang_info.app_name
    mix_config = lib_mix_info.mix_config

    # Get the ebin directory from the library
    lib_beam_dirs = lib_erlang_info.beam
    lib_priv_dirs = lib_erlang_info.priv

    # Build ERL_LIBS for all dependencies
    erl_libs_dir = ctx.label.name + "_deps"
    lib_deps = lib_erlang_info.deps

    erl_libs_files = erl_libs_contents(
        ctx,
        dir = erl_libs_dir,
        deps = lib_deps,
    )

    package = ctx.label.package
    erl_libs_path = path_join(package, erl_libs_dir)

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx, short_path = True)

    # User-provided environment variables
    user_env = "\n".join([
        "export {}={}".format(k, shell.quote(v))
        for k, v in ctx.attr.env.items()
    ])

    output = ctx.actions.declare_file(ctx.label.name)

    # Build test path arguments
    test_paths = ""
    if ctx.files.srcs:
        paths = []
        for s in ctx.files.srcs:
            if package and s.short_path.startswith(package + "/"):
                relative_path = s.short_path[len(package) + 1:]
                paths.append(relative_path)
            else:
                paths.append(s.short_path)
        test_paths = " ".join(paths)

    # Get library paths
    lib_ebin_path = ""
    if lib_beam_dirs:
        lib_ebin_path = lib_beam_dirs[0].short_path

    lib_priv_path = ""
    if lib_priv_dirs:
        lib_priv_path = lib_priv_dirs[0].short_path

    # Collect and sort services
    services = _collect_services(ctx)
    sorted_services = topological_sort_services(services) if services else []

    # Generate service orchestration code
    service_setup, _, service_env = _generate_service_orchestration(sorted_services)

    script = """\
#!/usr/bin/env bash
set -eo pipefail

{maybe_install_erlang}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

# Create TEST_TMPDIR if not set (for local runs)
if [[ -z "$TEST_TMPDIR" ]]; then
    TEST_TMPDIR=$(mktemp -d)
    export TEST_TMPDIR
fi

{service_setup}

# Navigate to the mix project root
cd "$TEST_SRCDIR/$TEST_WORKSPACE/{package}"

# Set up ERL_LIBS for dependencies
ERL_LIBS_PATH=""
if [[ -n "{erl_libs_path}" && -d "$TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path}" ]]; then
    ERL_LIBS_PATH="$(realpath $TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path})"
fi
export ERL_LIBS="$ERL_LIBS_PATH"

export HOME=/tmp
export MIX_HOME=/tmp/.mix
export MIX_ENV=test

# Service environment variables
{service_env}

# User environment variables
{user_env}

# User setup commands
{setup}

# Set up _build directory structure with pre-compiled artifacts
mkdir -p _build/test/lib/{app_name}/ebin

# Copy pre-compiled .beam and .app files from the mix_library
LIB_EBIN_PATH="$TEST_SRCDIR/$TEST_WORKSPACE/{lib_ebin_path}"
if [[ -d "$LIB_EBIN_PATH" ]]; then
    cp -r "$LIB_EBIN_PATH"/* _build/test/lib/{app_name}/ebin/
fi

# Copy priv directory if it exists
if [[ -n "{lib_priv_path}" ]]; then
    LIB_PRIV_PATH="$TEST_SRCDIR/$TEST_WORKSPACE/{lib_priv_path}"
    if [[ -d "$LIB_PRIV_PATH" ]]; then
        mkdir -p _build/test/lib/{app_name}/priv
        cp -r "$LIB_PRIV_PATH"/* _build/test/lib/{app_name}/priv/
    fi
fi

# Set up dependency directories and build PA_OPTIONS
PA_OPTIONS="-pa _build/test/lib/{app_name}/ebin"
if [[ -n "$ERL_LIBS_PATH" ]]; then
    for app_dir in "$ERL_LIBS_PATH"/*; do
        app_basename=$(basename "$app_dir")
        if [[ -d "$app_dir/ebin" ]]; then
            mkdir -p "_build/test/lib/$app_basename/ebin"
            cp -r "$app_dir/ebin"/* "_build/test/lib/$app_basename/ebin/"
            PA_OPTIONS="$PA_OPTIONS -pa $app_dir/ebin"
        fi
        if [[ -d "$app_dir/priv" ]]; then
            mkdir -p "_build/test/lib/$app_basename/priv"
            cp -r "$app_dir/priv"/* "_build/test/lib/$app_basename/priv/"
        fi
    done
fi

echo "[itest] Running integration tests..."

# Run mix test with --no-compile to use pre-compiled artifacts
MIX_ENV=test \\
    MIX_BUILD_ROOT=_build \\
    MIX_HOME=/tmp \\
    MIX_OFFLINE=true \\
    ELIXIR_ERL_OPTIONS="$PA_OPTIONS" \\
    ERL_LIBS="$ERL_LIBS_PATH" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix test --no-compile --no-start --no-deps-check {test_paths} {mix_test_opts}

TEST_EXIT_CODE=$?
echo "[itest] Tests completed with exit code $TEST_EXIT_CODE"
exit $TEST_EXIT_CODE
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        package = package,
        app_name = app_name,
        lib_ebin_path = lib_ebin_path,
        lib_priv_path = lib_priv_path,
        service_setup = service_setup,
        service_env = service_env,
        user_env = user_env,
        setup = ctx.attr.setup,
        test_paths = test_paths,
        mix_test_opts = " ".join([shell.quote(opt) for opt in ctx.attr.mix_test_opts]),
    )

    ctx.actions.write(
        output = output,
        content = script,
    )

    # Collect all files needed at runtime
    lib_files = []
    for beam_dir in lib_beam_dirs:
        lib_files.append(beam_dir)
    for priv_dir in lib_priv_dirs:
        lib_files.append(priv_dir)

    # Collect service runfiles
    service_runfiles = []
    for svc in sorted_services:
        service_runfiles.append(svc.data_runfiles)

    runfiles = erlang_runfiles.merge(elixir_runfiles)
    runfiles = runfiles.merge_all(
        [
            ctx.runfiles(
                ctx.files.srcs +
                ctx.files.data +
                erl_libs_files +
                lib_files +
                [mix_config],
            ),
        ] +
        service_runfiles +
        [
            tool[DefaultInfo].default_runfiles
            for tool in ctx.attr.tools
        ],
    )

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

mix_integration_test = rule(
    implementation = _mix_integration_test_impl,
    attrs = {
        "lib": attr.label(
            mandatory = True,
            providers = [ErlangAppInfo, MixProjectInfo],
            doc = "The mix_library target containing compiled application (must have mix_env='test')",
        ),
        "services": attr.label_list(
            providers = [ServiceInfo],
            doc = "Services to start before running tests",
        ),
        "srcs": attr.label_list(
            allow_files = [".exs"],
            doc = "Test files to run. If empty, all discovered tests are run.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional data files needed for tests",
        ),
        "tools": attr.label_list(
            cfg = "target",
            doc = "Additional tools needed for tests",
        ),
        "env": attr.string_dict(
            doc = "Additional environment variables to set during test execution",
        ),
        "setup": attr.string(
            doc = "Shell commands to run before executing tests (after services are started)",
        ),
        "mix_test_opts": attr.string_list(
            doc = "Additional options to pass to 'mix test'",
        ),
    },
    toolchains = ["//:toolchain_type"],
    test = True,
)
