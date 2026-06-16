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
