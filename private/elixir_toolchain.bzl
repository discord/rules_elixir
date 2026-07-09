load(
    "@rules_erlang//private:erlang_build.bzl",
    "OtpInfo",
)
load(
    "@rules_erlang//tools:erlang_toolchain.bzl",
    "erlang_home",
    "otp_rootdir_setup",
    "otp_runfiles",
)
load(
    ":elixir_build.bzl",
    "ElixirInfo",
)

def _impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        otpinfo = ctx.attr.elixir[OtpInfo],
        elixirinfo = ctx.attr.elixir[ElixirInfo],
    )
    return [toolchain_info]

elixir_toolchain = rule(
    implementation = _impl,
    attrs = {
        "elixir": attr.label(
            mandatory = True,
            providers = [OtpInfo, ElixirInfo],
        ),
    },
    provides = [platform_common.ToolchainInfo],
)

def _build_info(ctx):
    return ctx.toolchains["//:toolchain_type"].otpinfo

def erlang_dirs(ctx):
    info = _build_info(ctx)

    # erl.exe resolves its root from erl.ini, not $ERL_ROOTDIR, so a relocatable
    # (release_dir) toolchain can't work on a Windows target -- fail loudly rather
    # than emit a broken script. Use an external (host) erlang on Windows.
    if getattr(ctx.attr, "is_windows", False) and info.release_dir != None:
        fail("relocatable OTP toolchain (release_dir) is unsupported on Windows " +
             "targets: erl.exe reads its root from erl.ini, not $ERL_ROOTDIR. " +
             "Use an external (host) erlang toolchain for Windows.")

    return (erlang_home(info), info.release_dir, otp_runfiles(ctx, info))

def elixir_dirs(ctx, short_path = False):
    info = ctx.toolchains["//:toolchain_type"].elixirinfo
    if info.elixir_home != None:
        return (info.elixir_home, ctx.runfiles([info.version_file]))
    else:
        p = info.release_dir.short_path if short_path else info.release_dir.path
        return (p, ctx.runfiles([info.release_dir, info.version_file]))

def erl_rootdir_setup(ctx, short_path = False):
    """ERL_ROOTDIR export for the elixir toolchain's OTP; delegates to the pure
    otp_rootdir_setup in @rules_erlang//tools:erlang_toolchain.bzl. short_path=True
    for a runfiles (bazel run/test) context, False for a build action."""
    return otp_rootdir_setup(_build_info(ctx), short_path)

def erlang_escript_wrapper(ctx, wrapper_name, tool, exec_line = None):
    """Write a bash wrapper that puts the toolchain's Erlang/OTP on PATH and execs an escript.

    Handles relocatable OTP via $ERL_ROOTDIR, so the same wrapper works for
    external and internal toolchains.

    Args:
      ctx: the rule context.
      wrapper_name: filename to declare for the generated wrapper script.
      tool: the escript File to exec (its path is used in the default exec line).
      exec_line: overrides the default `exec "<tool>" "$@"` (e.g. to append flags).

    Returns:
      (wrapper_file, erlang_runfiles). Callers must feed erlang_runfiles.files
      into the action's inputs so the OTP release tree is staged.
    """
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    if exec_line == None:
        exec_line = 'exec "{}" "$@"'.format(tool.path)
    wrapper = ctx.actions.declare_file(wrapper_name)
    ctx.actions.write(
        output = wrapper,
        content = """#!/bin/bash
set -euo pipefail

{erl_rootdir_setup}

# Set up Erlang/OTP paths
export PATH="{erlang_home}/bin:$PATH"

{exec_line}
""".format(
            erl_rootdir_setup = erl_rootdir_setup(ctx),
            erlang_home = erlang_home,
            exec_line = exec_line,
        ),
        is_executable = True,
    )
    return (wrapper, erlang_runfiles)
