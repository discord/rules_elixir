"""Rules for evaluating all Elixir application configurations.

This module provides a Bazel rule for evaluating ALL application configurations
from Elixir config/*.exs files and encoding them as EETF (Erlang External Term Format).
"""

load("//:elixir_app_info.bzl", "ElixirAppInfo")
load("@rules_erlang//:util.bzl", "path_join")

def _eval_config_impl(ctx):
    """Evaluate all Elixir application configurations using the eval_config tool."""

    # Get the toolchain
    toolchain = ctx.toolchains["//:toolchain_type"]
    erlang_toolchain = toolchain.otpinfo

    # Determine output file name
    output_name = ctx.attr.output_name
    if not output_name:
        output_name = "config_{}.eetf".format(ctx.attr.env)

    # Declare output files
    eetf_file = ctx.actions.declare_file(output_name)
    debug_file = None
    if not ctx.attr.no_debug:
        debug_file = ctx.actions.declare_file(output_name + ".debug")

    # Get the eval_config tool
    tool = ctx.executable._eval_config

    # Create a wrapper script that sets up the PATH for escript
    wrapper = ctx.actions.declare_file("{}_wrapper.sh".format(ctx.attr.name))

    # Build the wrapper script content
    wrapper_content = """#!/bin/bash
set -euo pipefail

# Set up Erlang/OTP paths
export PATH="{erlang_home}/bin:$PATH"

# Run the escript with all arguments
exec "{tool_path}" "$@"
""".format(
        erlang_home = erlang_toolchain.erlang_home,
        tool_path = tool.path,
    )

    ctx.actions.write(
        output = wrapper,
        content = wrapper_content,
        is_executable = True,
    )

    # Build arguments for eval_config tool
    args = ctx.actions.args()

    # Required arguments
    args.add("--env", ctx.attr.env)
    args.add("--output", eetf_file.path)

    # Base directory (for resolving config file paths)
    if ctx.attr.base_dir:
        if ctx.files.base_dir:
            # If base_dir is a label pointing to files
            base_dir_path = ctx.files.base_dir[0].dirname
            args.add("--base-dir", base_dir_path)
        else:
            # If base_dir is a string path
            args.add("--base-dir", ctx.attr.base_dir)
    elif ctx.files.config_files:
        # Infer base directory from first config file
        first_config = ctx.files.config_files[0]
        if "/config/" in first_config.path:
            base_dir = first_config.path.rsplit("/config/", 1)[0]
            args.add("--base-dir", base_dir)
        elif "config/" in first_config.path:
            # Handle relative path like "config/config.exs"
            base_dir = first_config.path.rsplit("config/", 1)[0]
            if not base_dir or base_dir == "":
                base_dir = "."
            args.add("--base-dir", base_dir)
        else:
            # Default to current directory
            args.add("--base-dir", ".")

    # Optional flags
    if ctx.attr.verbose:
        args.add("--verbose")

    if ctx.attr.no_imports:
        args.add("--no-imports")

    if ctx.attr.no_debug:
        args.add("--no-debug")

    # Collect inputs - config files, the tool, and any extra inputs
    inputs = depset(
        direct = ctx.files.config_files + ctx.files.extra_inputs + [tool],
    )

    # Determine outputs
    outputs = [eetf_file]
    if debug_file and not ctx.attr.no_debug:
        outputs.append(debug_file)

    # Run the eval_config tool via the wrapper
    ctx.actions.run(
        executable = wrapper,
        arguments = [args],
        inputs = inputs,
        outputs = outputs,
        mnemonic = "EvalConfig",
        progress_message = "Evaluating all app configs [{}]".format(ctx.attr.env),
        # Set environment variables if needed
        env = {
            "MIX_ENV": ctx.attr.env,
        },
    )

    # Return providers - only provide the EETF file, not the debug file
    providers = [
        DefaultInfo(
            files = depset([eetf_file]),
        ),
    ]

    # Optionally provide ElixirAppInfo
    if ctx.attr.provide_app_info:
        providers.append(ElixirAppInfo(
            config = eetf_file,
        ))

    return providers

eval_config = rule(
    implementation = _eval_config_impl,
    toolchains = ["//:toolchain_type"],
    attrs = {
        "env": attr.string(
            default = "prod",
            doc = "The environment to evaluate config for (prod, dev, test, etc.)",
        ),
        "config_files": attr.label_list(
            allow_files = [".exs"],
            mandatory = True,
            doc = "List of Elixir config files (config/*.exs)",
        ),
        "base_dir": attr.label(
            allow_files = True,
            doc = "Base directory for resolving config file paths (optional)",
        ),
        "output_name": attr.string(
            doc = "Custom output filename (defaults to config_<env>.eetf)",
        ),
        "extra_inputs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Additional files needed during config evaluation",
        ),
        "verbose": attr.bool(
            default = False,
            doc = "Enable verbose output from the eval tool",
        ),
        "no_imports": attr.bool(
            default = False,
            doc = "Disable processing of import_config statements",
        ),
        "no_debug": attr.bool(
            default = False,
            doc = "Disable generation of .debug file",
        ),
        "provide_app_info": attr.bool(
            default = True,
            doc = "Whether to provide ElixirAppInfo with the evaluated config",
        ),
        "_eval_config": attr.label(
            default = Label("//tools/eval_config"),
            executable = True,
            cfg = "exec",
            doc = "The eval_config escript tool",
        ),
    },
    provides = [DefaultInfo],
)