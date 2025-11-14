"""Rules for consolidating Elixir protocols.

Protocol consolidation improves performance by pre-compiling protocol dispatch
at build time rather than runtime. This matches Mix's behavior during releases.
"""

load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load("//:elixir_app_info.bzl", "ElixirAppInfo")

def _elixir_protocol_consolidation_impl(ctx):
    """Consolidate protocols from Elixir applications."""

    # Collect all beam files and their directories from dependencies
    ebin_dirs = []
    beam_files = []

    for dep in ctx.attr.deps:
        if ErlangAppInfo in dep:
            app_info = dep[ErlangAppInfo]
            # Collect all beam files
            beam_files.extend(app_info.beam)
            # Extract ebin directories from beam file paths
            for beam_file in app_info.beam:
                ebin_dir = beam_file.dirname
                if ebin_dir not in ebin_dirs:
                    ebin_dirs.append(ebin_dir)

    if not ebin_dirs:
        fail("No dependencies with ErlangAppInfo found")

    # Create output directory for consolidated protocols
    output_dir = ctx.actions.declare_directory("{}_consolidated".format(ctx.attr.name))

    # Get the protocol_consolidator tool
    consolidator = ctx.executable._protocol_consolidator

    # Get the toolchain for Erlang paths
    toolchain = ctx.toolchains["//:toolchain_type"]
    erlang_toolchain = toolchain.otpinfo

    # Create a wrapper script that sets up the PATH for escript
    wrapper = ctx.actions.declare_file("{}_consolidator_wrapper.sh".format(ctx.attr.name))

    # Build the wrapper script content
    wrapper_content = """#!/bin/bash
set -euo pipefail

# Set up Erlang/OTP paths
export PATH="{erlang_home}/bin:$PATH"

# Run the protocol consolidator escript
exec "{tool_path}" "$@"
""".format(
        erlang_home = erlang_toolchain.erlang_home,
        tool_path = consolidator.path,
    )

    ctx.actions.write(
        output = wrapper,
        content = wrapper_content,
        is_executable = True,
    )

    # Build arguments for consolidator
    args = ctx.actions.args()
    args.add(output_dir.path)

    # Add all ebin directories as input paths
    for ebin_dir in ebin_dirs:
        args.add(ebin_dir)

    # Run the protocol consolidator
    ctx.actions.run(
        executable = wrapper,
        arguments = [args],
        inputs = depset(beam_files + [consolidator]),
        outputs = [output_dir],
        mnemonic = "ConsolidateProtocols",
        progress_message = "Consolidating protocols for {}".format(ctx.label),
        # Set environment variables if needed
        env = {
            "MIX_ENV": ctx.attr.env,
        },
    )

    # Return providers
    return [
        DefaultInfo(
            files = depset([output_dir]),
        ),
        ProtocolConsolidationInfo(
            consolidated_dir = output_dir,
            source_deps = ctx.attr.deps,
        ),
    ]

elixir_protocol_consolidation = rule(
    implementation = _elixir_protocol_consolidation_impl,
    toolchains = ["//:toolchain_type"],
    attrs = {
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
            mandatory = True,
            doc = "List of Elixir/Erlang applications to consolidate protocols from",
        ),
        "env": attr.string(
            default = "prod",
            doc = "Environment (prod, dev, test)",
        ),
        "_protocol_consolidator": attr.label(
            default = Label("//tools/protocol_consolidator"),
            executable = True,
            cfg = "exec",
            doc = "The protocol consolidator escript tool",
        ),
    },
    provides = [DefaultInfo],
)

# Provider for protocol consolidation information
ProtocolConsolidationInfo = provider(
    doc = "Information about consolidated protocols",
    fields = {
        "consolidated_dir": "Directory containing consolidated protocol beams",
        "source_deps": "Original dependencies the protocols were consolidated from",
    },
)

def consolidate_protocols_for_release(name, deps, **kwargs):
    """Convenience macro to consolidate protocols for a release.

    Args:
        name: Name of the target
        deps: List of dependencies to consolidate protocols from
        **kwargs: Additional arguments passed to elixir_protocol_consolidation

    This creates a target that consolidates all protocols from the given
    dependencies and produces a directory of consolidated beam files that
    should be included in the release's consolidated/ directory.
    """
    elixir_protocol_consolidation(
        name = name,
        deps = deps,
        **kwargs
    )

    # Also create an alias for easier reference
    native.alias(
        name = "{}_dir".format(name),
        actual = name,
        visibility = ["//visibility:public"],
    )