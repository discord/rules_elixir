load(
    "@rules_erlang//private:erlang_build.bzl",
    "OtpInfo",
)
load(
    "@rules_erlang//tools:erlang_toolchain.bzl",
    "erlang_home",
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
    if info.release_dir != None:
        runfiles = ctx.runfiles([
            info.release_dir,
            info.version_file,
        ])
    else:
        runfiles = ctx.runfiles([
            info.version_file,
        ])
    return (erlang_home(info), info.release_dir, runfiles)

def elixir_dirs(ctx, short_path = False):
    info = ctx.toolchains["//:toolchain_type"].elixirinfo
    if info.elixir_home != None:
        return (info.elixir_home, ctx.runfiles([info.version_file]))
    else:
        p = info.release_dir.short_path if short_path else info.release_dir.path
        return (p, ctx.runfiles([info.release_dir, info.version_file]))

def maybe_install_erlang(ctx, short_path = False):
    """Shell that exports ERL_ROOTDIR so a templated "$ERL_ROOTDIR"/bin/erl resolves.

    Pairs with erlang_home(): that emits the "$ERL_ROOTDIR" reference (for a
    relocatable OTP install), this gives it a value. Empty for an external/host
    erlang, which carries an absolute erlang_home and needs no setup.

    Pass short_path = True when the generated script runs from a runfiles tree
    (an executable launched by `bazel run`/`bazel test`); leave it False (the
    default) when the script runs inside a build action, where cwd is the
    execroot. Mirrors erl_rootdir_setup() in
    @rules_erlang//tools:erlang_toolchain.bzl.
    """
    info = _build_info(ctx)
    release_dir = info.release_dir
    if release_dir == None:
        return ""
    if short_path:
        return """\
if [ -n "${{TEST_SRCDIR:-}}" ]; then
    export ERL_ROOTDIR="$TEST_SRCDIR/$TEST_WORKSPACE/{short_path}"
else
    export ERL_ROOTDIR="$PWD/{short_path}"
fi\
""".format(short_path = release_dir.short_path)
    else:
        return 'export ERL_ROOTDIR="$PWD/{}"'.format(release_dir.path)
