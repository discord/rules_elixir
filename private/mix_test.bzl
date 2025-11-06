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

def _mix_test_impl(ctx):
    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        dir = erl_libs_dir,
        deps = flat_deps(ctx.attr.deps),
        # NOTE: even though we provide `ez_deps` here, these don't actually
        # correctly get added to our necessary include path. We explicitly set
        # MIX_ARCHIVES later to placate mix here.
        # TODO: improve this? it would be nice if we didn't have to do
        # explicit further handling for .ez files.
        ez_deps = ctx.files.ez_deps,
        expand_ezs = False,
    )

    package = ctx.label.package
    erl_libs_path = path_join(package, erl_libs_dir)

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx, short_path = True)

    env = "\n".join([
        "export {}={}".format(k, v)
        for k, v in ctx.attr.env.items()
    ])

    output = ctx.actions.declare_file(ctx.label.name)

    # Build test path arguments if specific test files are provided
    test_paths = ""
    if ctx.files.srcs:
        test_paths = " ".join([s.short_path for s in ctx.files.srcs])

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

# Set up ERL_LIBS for dependencies
export ERL_LIBS="$TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path}"

# Navigate to the mix project root
cd "$TEST_SRCDIR/$TEST_WORKSPACE/{package}"

export HOME=${{PWD}}
export MIX_HOME=/tmp/.mix
export MIX_ENV=test

{env}

{setup}

# Run mix test
set -x
MIX_ENV=test \\
    ELIXIR_ERL_OPTIONS="-pa $ERL_LIBS" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix test {test_paths} {mix_test_opts} \\
    | tee "${{TEST_UNDECLARED_OUTPUTS_DIR}}/test.log"
set +x

# Verify tests passed (no failures)
tail -n 10 "${{TEST_UNDECLARED_OUTPUTS_DIR}}/test.log" | grep -E --silent "0 failures"
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        package = package,
        env = env,
        setup = ctx.attr.setup,
        test_paths = test_paths,
        mix_test_opts = " ".join([shell.quote(opt) for opt in ctx.attr.mix_test_opts]),
    )

    ctx.actions.write(
        output = output,
        content = script,
    )

    # Include mix.exs and any additional data files in runfiles
    runfiles = erlang_runfiles.merge(elixir_runfiles)
    runfiles = runfiles.merge_all(
        [
            ctx.runfiles(
                ctx.files.srcs +
                ctx.files.data +
                erl_libs_files +
                ([ctx.file.mix_config] if ctx.file.mix_config else [])
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
        "mix_config": attr.label(
            allow_single_file = [".exs"],
            default = ":mix.exs",
            doc = "The mix.exs configuration file for the project",
        ),
        "srcs": attr.label_list(
            allow_files = [".ex", ".exs"],
            doc = "Optional list of specific test files to run. If empty, runs all tests.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional data files needed for tests",
        ),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
            doc = "Dependencies required for the tests",
        ),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
            doc = "Erlang/Elixir archive dependencies",
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
        "mix_test_opts": attr.string_list(
            doc = "Additional options to pass to 'mix test'",
        ),
    },
    toolchains = ["//:toolchain_type"],
    test = True,
)
