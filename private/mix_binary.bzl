load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")

# TODO: this will eventiuallty break, because we are loading from a directory
# called private
load("@rules_erlang//private:util.bzl", "erl_libs_contents")
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
)
load("//private:mix_info.bzl", "MixProjectInfo")

def _mix_binary_impl(ctx):
    # TODO: run mix_release and output this

    erl_libs_dir = ctx.label.name + "_deps"

    erlang_info = ctx.attr.application[ErlangAppInfo]

    # NOTE: cargo-culted, needs further understanding
    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = True,
        dir = erl_libs_dir,
        # TODO: direct_deps seems defined only in an unreleased version of
        # rules_erlang
        deps = erlang_info.deps,
        # ez_deps = ctx.files.ez_deps,
        ez_deps = [],
        expand_ezs = True,
    )

    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        )

    # NOTE: end cargo-cult

    # this has to be a label, instead of a string
    app_config_file = ctx.attr.application[MixProjectInfo].mix_config
    files = [app_config_file]
    if erlang_info.beam:
        files.append(erlang_info.beam)
    runfiles = ctx.runfiles(files = files)

    exe = ctx.actions.declare_file(ctx.label.name)

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    script = """set -euo pipefail

if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

set -x
cd {build_dir}

mkdir _output
# export MIX_BUILD_ROOT=$PWD/_output
# WHERE WE'RE GOIN WE DON'T NEED NO OS CONCURRENCY LOCKS
export MIX_OS_CONCURRENCY_LOCK=false

# TODO: we should probably consolidate these somewhere?
export HEX_OFFLINE=true

# Build -pa options for each dependency's ebin directory
ERL_LIBS_PATH="{erl_libs_path}"
PA_OPTIONS=""
if [[ -n "$ERL_LIBS_PATH" ]]; then
    for app_dir in "$ERL_LIBS_PATH"/*; do
        if [[ -d "$app_dir/ebin" ]]; then
            PA_OPTIONS="$PA_OPTIONS -pa $app_dir/ebin"
        fi
    done
fi

MIX_ENV=prod \\
    MIX_HOME="$(mktemp -d)" \\
    ELIXIR_ERL_OPTIONS="$PA_OPTIONS" \\
    ERL_LIBS="{beam_files}/ebin/ebin/lib/main:{erl_libs_path}" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix release --no-compile --no-deps-check

ls -laR _build/prod/rel/{app_name}

mv _build/prod/rel/{app_name}/bin/{app_name} {output_file}
""".format(
        beam_files = erlang_info.beam.dirname,
        maybe_install_erlang = maybe_install_erlang(ctx),
        elixir_home = elixir_home,
        erlang_home = erlang_home,
        erl_libs_path = erl_libs_path,
        # I think these should be provided via a runfiles struct....right?
        build_dir = app_config_file.dirname,
        app_name = erlang_info.app_name,
        output_file = exe.path,
    )

    # TODO: need to make this uh, better and less cargo-culty
    inputs = depset(
        direct = files,
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
        ],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [exe],
        command = script,
        mnemonic = "MIXRELEASE",
    )

    return [
        DefaultInfo(executable = exe),
    ]

mix_binary = rule(
    implementation = _mix_binary_impl,
    executable = True,
    attrs = {
        "app_name": attr.string(),
        "application": attr.label(providers = [MixProjectInfo, ErlangAppInfo]),
    },
    # TODO: demystify
    toolchains = ["//:toolchain_type"],
)
