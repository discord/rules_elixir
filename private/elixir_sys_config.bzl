"""Rules for generating Erlang sys.config files with Elixir Config.Provider support.

This module provides rules for creating sys.config files with intelligent defaults
and automatic inference of common configuration values.

This is probably one of the most "magic" and "scary" parts of the bundling process,
because it changes a number of opaque-looking build params and uses words like
"boot injection".

In reality, it just encodes the the compile-time configuration into a compact EETF
format that gets read by the boot script, and conditionally adds a config section
to invoke `Elixir.Config.Provider` on boot, so that Elixir will evaluate the
`runtime.exs` that gets baked into the release, and merge it with its' runtime
configs.

Practically, this is used for providing runtime information in application
configuration, e.g., reading environment variables, recording startup time, hostname,
resolving files on local filesystem, etc

In future, if we ever wanted to provide a custom Config.Provider implementation,
or provide different parameteres to the default Config.Reader, we would have to
extend this to also inject specs for these into `sys.config`.
"""

load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load("//:elixir_app_info.bzl", "ElixirAppInfo")
load(":release_info.bzl", "ReleaseInfo", "get_release_info")
load(
    ":config_inference.bzl",
    "infer_app_name",
    "infer_env",
    "infer_runtime_config_path",
    "infer_version",
    "parse_config_provider_options",
    "should_use_runtime_config",
)

def _elixir_sys_config_impl(ctx):
    """Generate a sys.config file with intelligent defaults and inference."""

    # Infer configuration values
    env = infer_env(ctx)
    version = infer_version(ctx)
    app_name = infer_app_name(ctx)

    # Collect all compile-time configs
    compile_configs = []
    for config_file in ctx.files.app_configs:
        compile_configs.append(config_file)

    # Determine if we need runtime config
    has_runtime = len(ctx.files.runtime_configs) > 0
    runtime_config_path = infer_runtime_config_path(ctx) if has_runtime else None

    # Parse Config.Provider options
    provider_options = parse_config_provider_options(ctx)

    # Generate sys.config output file
    sys_config = ctx.actions.declare_file("{}.sys.config".format(ctx.attr.name))

    # Generate boot script injection file if we have runtime configs
    boot_injection = None
    if has_runtime:
        boot_injection = ctx.actions.declare_file("{}.boot_inject".format(ctx.attr.name))

    # Build arguments for the sys_config_builder tool
    args = ctx.actions.args()
    args.add("--output", sys_config.path)

    # Add compile-time configs
    for config in compile_configs:
        args.add("--compile-config", config.path)

    # Add runtime config settings if applicable
    if has_runtime:
        args.add("--runtime-config")
        for runtime_config in ctx.files.runtime_configs:
            args.add("--runtime-file", runtime_config.path)

        # Use the inferred runtime config path
        args.add("--runtime-path", runtime_config_path)

        # Config.Provider options from parsed dict
        if provider_options["reboot_after_config"]:
            args.add("--reboot-after-config")

        if provider_options["prune_after_boot"]:
            args.add("--prune-after-boot")

        # Generate boot injection file
        args.add("--boot-injection", boot_injection.path)

    # Add extra static config if provided
    if ctx.attr.extra_config:
        for app, config_str in ctx.attr.extra_config.items():
            args.add("--extra-app", app)
            args.add("--extra-config", config_str)

    # Add the inferred environment
    args.add("--env", env)

    # Get the sys_config_builder tool
    builder = ctx.executable._sys_config_builder

    # Get the toolchain for Erlang paths
    toolchain = ctx.toolchains["//:toolchain_type"]
    erlang_toolchain = toolchain.otpinfo

    # Create a wrapper script that sets up the PATH for escript
    wrapper = ctx.actions.declare_file("{}_sys_config_wrapper.sh".format(ctx.attr.name))
    wrapper_content = """#!/bin/bash
set -euo pipefail

# Set up Erlang/OTP paths
export PATH="{erlang_home}/bin:$PATH"

# Run the escript with all arguments
exec "{tool_path}" "$@"
""".format(
        erlang_home = erlang_toolchain.erlang_home,
        tool_path = builder.path,
    )

    ctx.actions.write(
        output = wrapper,
        content = wrapper_content,
        is_executable = True,
    )

    # Prepare inputs
    inputs = compile_configs + ctx.files.runtime_configs + [builder]

    # Prepare outputs
    outputs = [sys_config]
    if boot_injection:
        outputs.append(boot_injection)

    # Run the sys_config_builder tool via the wrapper
    ctx.actions.run(
        executable = wrapper,
        arguments = [args],
        inputs = depset(inputs),
        outputs = outputs,
        mnemonic = "SysConfig",
        progress_message = "Generating sys.config for {}".format(ctx.label),
    )

    # Return providers including enhanced SysConfigInfo
    return [
        DefaultInfo(
            files = depset([sys_config] + ([boot_injection] if boot_injection else [])),
        ),
        SysConfigInfo(
            sys_config = sys_config,
            boot_injection = boot_injection,
            has_runtime_config = has_runtime,
            reboot_after_config = provider_options["reboot_after_config"],
            # Enhanced fields for better integration
            env = env,
            version = version,
            app_name = app_name,
        ),
    ]

elixir_sys_config = rule(
    implementation = _elixir_sys_config_impl,
    toolchains = ["//:toolchain_type"],
    attrs = {
        # Core attributes (minimal required configuration)
        "app_configs": attr.label_list(
            mandatory = True,
            allow_files = [".eetf", ".eterm"],
            doc = """Compile-time configuration files from eval_config.

            These EETF files contain the compile-time configuration for all
            OTP applications. This is the primary input to sys.config generation.

            Example:
                app_configs = [":config_prod"]  # From eval_config
            """,
        ),

        "runtime_configs": attr.label_list(
            allow_files = [".exs"],
            default = [],
            doc = """Runtime configuration files (e.g., runtime.exs).

            When provided, enables Config.Provider support for runtime configuration.
            The files will be evaluated at release startup with access to environment
            variables.

            Example:
                runtime_configs = ["config/runtime.exs"]
            """,
        ),

        # Optional customization (rarely needed)
        "extra_config": attr.string_dict(
            default = {},
            doc = """Additional static configuration as Erlang terms.

            For cases where you need to inject configuration that isn't coming
            from eval_config. The dict keys are application names and
            values are Erlang term strings.

            Example:
                extra_config = {
                    "kernel": "[{logger_level, debug}]",
                    "stdlib": "[{some_option, true}]",
                }

            Note: This is error-prone and should be avoided. Prefer using
            proper config files with eval_config instead.
            """,
        ),

        "config_provider_options": attr.string_dict(
            default = {},
            doc = """Advanced Config.Provider options.

            Available options:
            - reboot_after_config: "true" or "false" (default: "false")
              Whether to restart the VM after loading runtime configuration.
              Only needed if runtime config modifies critical system apps.

            - prune_after_boot: "true" or "false" (default: "true")
              Whether to delete temporary sys.config files after boot.
              Set to "false" for debugging.

            Example:
                config_provider_options = {
                    "reboot_after_config": "true",
                    "prune_after_boot": "false",
                }
            """,
        ),

        # Context providers (for inference)
        "release": attr.label(
            providers = [ReleaseInfo],
            doc = """Release target providing ReleaseInfo for inference.

            When provided, the rule will infer version, environment, and other
            values from the ReleaseInfo provider. This enables better integration
            with mix_release and reduces configuration duplication.

            Example:
                release = ":my_release"  # Target providing ReleaseInfo
            """,
        ),

        # Explicit overrides (only if inference fails or needs override)
        "env": attr.string(
            doc = """Explicitly set the environment (prod/dev/test).

            By default, this is inferred from:
            1. ReleaseInfo provider if available
            2. Naming convention of app_configs targets
            3. Defaults to "prod"

            Only set this if inference is incorrect or you need to override.

            Example:
                env = "staging"  # Custom environment
            """,
        ),

        "version": attr.string(
            doc = """Explicitly set the release version.

            By default, this is inferred from:
            1. ReleaseInfo provider if available
            2. Defaults to "0.1.0"

            Only set this if inference is incorrect or you need to override.
            This version is used to construct runtime config paths.

            Example:
                version = "2.3.4"
            """,
        ),

        # Internal tools
        "_sys_config_builder": attr.label(
            default = Label("//tools/sys_config_builder"),
            executable = True,
            cfg = "exec",
            doc = "Internal: Tool for building sys.config files",
        ),
    },
    provides = [DefaultInfo],
)

# Enhanced provider for sys.config information
SysConfigInfo = provider(
    doc = """Information about generated sys.config files.

    This provider includes metadata for better integration
    with other rules and improved debugging.
    """,
    fields = {
        "sys_config": "The generated sys.config file",
        "boot_injection": "Boot script injection file (if runtime config exists)",
        "has_runtime_config": "Whether runtime configuration is enabled",
        "reboot_after_config": "Whether system will reboot after config",
        # Enhanced fields for better integration
        "env": "The environment this config was generated for",
        "version": "The version used for runtime config paths",
        "app_name": "The inferred or explicit application name",
    },
)
