load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)
load("//private:mix_info.bzl", "MixProjectInfo")

def _mix_test_impl(ctx):
    lib_erlang_info = ctx.attr.lib[ErlangAppInfo]
    lib_mix_info = ctx.attr.lib[MixProjectInfo]

    if lib_mix_info.mix_env != "test":
        fail("mix_test requires a mix_library compiled with mix_env='test'. " +
             "Target '{}' was compiled with mix_env='{}'. ".format(ctx.attr.lib.label, lib_mix_info.mix_env) +
             "Create a separate mix_library with mix_env='test' for testing.")

    app_name = lib_erlang_info.app_name
    mix_config = lib_mix_info.mix_config
    lib_beam_dirs = lib_erlang_info.beam
    lib_priv_dirs = lib_erlang_info.priv

    erl_libs_dir = ctx.label.name + "_deps"
    erl_libs_files = erl_libs_contents(
        ctx,
        dir = erl_libs_dir,
        deps = lib_erlang_info.deps,
    )

    package = ctx.label.package

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx, short_path = True)

    env = "\n".join([
        "export {}={}".format(k, v)
        for k, v in ctx.attr.env.items()
    ])

    output = ctx.actions.declare_file(ctx.label.name)

    # Strip package prefix from test paths since we cd into the package directory
    test_paths = ""
    if ctx.files.srcs:
        paths = []
        for s in ctx.files.srcs:
            # Remove package prefix from path since we cd into package dir
            if package and s.short_path.startswith(package + "/"):
                relative_path = s.short_path[len(package) + 1:]
                paths.append(relative_path)
            else:
                paths.append(s.short_path)
        test_paths = " ".join(paths)

    # Priv symlink: only emit if the main app has priv files.
    # After cd into package dir, "priv" is relative to cwd.
    priv_symlink = 'ln -s "$(realpath priv)" _build/test/lib/{app_name}/priv'.format(
        app_name = app_name,
    ) if lib_priv_dirs else ""

    script = """\
#!/usr/bin/env bash
set -eo pipefail

{install_erlang}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}
export HOME="$TEST_TMPDIR"
export MIX_ENV=test

# Bazel test runner sets TEST_SRCDIR and TEST_WORKSPACE.
# After cd, all runfiles paths are relative to the mix project root.
cd "$TEST_SRCDIR/$TEST_WORKSPACE/{package}"
DEPS_DIR="$(realpath {erl_libs_dir})"

{env}

{setup}

# Set up _build/test/lib with symlinks to Bazel-compiled outputs.
# With --no-compile, Mix is read-only — symlinks avoid copying entirely.
# Mix manages app code paths from _build; no -pa flags needed for deps.
mkdir -p _build/test/lib/{app_name}
ln -s "$(realpath {beam_dir})" _build/test/lib/{app_name}/ebin
{priv_symlink}

for app_dir in "$DEPS_DIR"/*; do
    ln -s "$app_dir" "_build/test/lib/$(basename "$app_dir")"
done

# OTP -pa: Erlang is extracted to a non-standard sandbox path.
OTP_PA=""
for otp_ebin in "{erlang_home}/lib"/*/ebin; do
    [ -d "$otp_ebin" ] && OTP_PA="$OTP_PA -pa $otp_ebin"
done

# ERL_LIBS: needed so Mix can find Hex (SCM provider for parsing mix.exs).
# In native Mix, Hex comes from ~/.mix/archives; in Bazel, MIX_HOME is empty.
MIX_ENV=test \\
    MIX_BUILD_ROOT=_build \\
    MIX_HOME="$TEST_TMPDIR/.mix" \\
    HEX_OFFLINE=true \\
    ELIXIR_ERL_OPTIONS="$OTP_PA" \\
    ERL_LIBS="$DEPS_DIR" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix test --no-compile {no_start}--no-deps-check {test_paths} {mix_test_opts}
""".format(
        install_erlang = maybe_install_erlang(ctx, short_path = True),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        package = package,
        app_name = app_name,
        beam_dir = lib_beam_dirs[0].basename,
        erl_libs_dir = erl_libs_dir,
        priv_symlink = priv_symlink,
        env = env,
        setup = ctx.attr.setup,
        no_start = "--no-start " if ctx.attr.no_start else "",
        test_paths = test_paths,
        mix_test_opts = " ".join([shell.quote(opt) for opt in ctx.attr.mix_test_opts]),
    )

    ctx.actions.write(
        output = output,
        content = script,
    )

    lib_files = list(lib_beam_dirs) + list(lib_priv_dirs)

    runfiles = erlang_runfiles.merge(elixir_runfiles)
    runfiles = runfiles.merge_all(
        [
            ctx.attr.lib[DefaultInfo].default_runfiles,
            ctx.runfiles(
                ctx.files.srcs +
                ctx.files.data +
                erl_libs_files +
                lib_files +
                [mix_config]
            ),
        ] + [
            tool[DefaultInfo].default_runfiles
            for tool in ctx.attr.tools
        ],
    )

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

mix_test = rule(
    implementation = _mix_test_impl,
    attrs = {
        "lib": attr.label(
            mandatory = True,
            providers = [ErlangAppInfo, MixProjectInfo],
            doc = "The mix_library target containing compiled application (must have mix_env='test')",
        ),
        "srcs": attr.label_list(
            allow_files = [".exs"],
            doc = "Test files to include in runfiles and optionally run. If specific files are provided, only those tests are run. If empty, all discovered tests are run.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional data files needed at test runtime (e.g., version files, config data referenced by mix.exs)",
        ),
        "tools": attr.label_list(
            cfg = "target",
            doc = "Additional tools needed for tests",
        ),
        "env": attr.string_dict(
            doc = "Environment variables to set during test execution",
        ),
        "setup": attr.string(
            doc = "Shell commands to run before executing tests",
        ),
        "no_start": attr.bool(
            default = False,
            doc = "If True, pass --no-start to mix test to prevent applications from being started before tests run",
        ),
        "mix_test_opts": attr.string_list(
            doc = "Additional options to pass to 'mix test'",
        ),
    },
    toolchains = ["//:toolchain_type"],
    test = True,
)
