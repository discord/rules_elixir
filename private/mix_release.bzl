load("//private:mix_info.bzl", "MixProjectInfo")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")
# TODO: this will eventiuallty break, because we are loading from a directory
# called private
load("@rules_erlang//private:util.bzl", "erl_libs_contents")
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _mix_release_impl(ctx):
    # TODO: run mix_release and output this

    erl_libs_dir = ctx.label.name + "_deps"

    erlang_info = ctx.attr.application[ErlangAppInfo]

    all_deps = [ctx.attr.application] + erlang_info.deps

    # NOTE: cargo-culted, needs further understanding
    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = True,
        dir = erl_libs_dir,
        deps = all_deps,
        ez_deps = ctx.files._hex_ez,
        expand_ezs = False,
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
        files.extend(erlang_info.beam)
    runfiles = ctx.runfiles(files = files)

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    mix_release_artifacts = ctx.actions.declare_directory('{}_release'.format(ctx.label.name))
    script = """set -euo pipefail

{maybe_install_erlang}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

ERL_LIBS_PATH="$(realpath {erl_libs_path})"
mkdir _output
OUTPUT_DIR="$(realpath _output)"
OUTPUT_FILE="$(realpath {output_file})"

set -x
cd {build_dir}

# export MIX_BUILD_ROOT=$PWD/_output
# WHERE WE'RE GOIN WE DON'T NEED NO OS CONCURRENCY LOCKS
export MIX_OS_CONCURRENCY_LOCK=false

# TODO: we should probably consolidate these somewhere?
export MIX_OFFLINE=true


mkdir -p "$OUTPUT_DIR/prod/lib"
for app_dir in "$ERL_LIBS_PATH"/*; do
    if [ -d "$app_dir/ebin" ]; then
        app_name=$(basename "$app_dir")
        mkdir -p "$OUTPUT_DIR/prod/lib/$app_name/ebin"
        cp -r "$app_dir/ebin"/* "$OUTPUT_DIR/prod/lib/$app_name/ebin/"
    fi
done

ls -lR "$ERL_LIBS_PATH"

MIX_ENV=prod \\
    MIX_BUILD_ROOT="$OUTPUT_DIR" \\
    HOME=/tmp \\
    MIX_HOME=/tmp \\
    ELIXIR_ERL_OPTIONS="-pa $ERL_LIBS_PATH" \\
    ERL_LIBS="$ERL_LIBS_PATH" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix release --no-compile --no-deps-check

cd -
mv $OUTPUT_DIR/prod/rel/{app_name} {output_file}
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        elixir_home = elixir_home,
        erlang_home = erlang_home,
        erl_libs_path = erl_libs_path,
        # I think these should be provided via a runfiles struct....right?
        build_dir = app_config_file.dirname,
        app_name = erlang_info.app_name,
        output_file = mix_release_artifacts.path,
    )


    # TODO: need to make this uh, better and less cargo-culty
    inputs = depset(
        direct = files + erl_libs_files,
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files
        ],
    )

    # this takes all the BEAM files, and outputs a new directory that has all
    # the outputs combines. The output is needed to build the executable
    # script
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [mix_release_artifacts],
        command = script,
        mnemonic = "MIXRELEASE",
    )

    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.executable,
        is_executable = True,
        substitutions = {
            "{BINARY_PATH}": mix_release_artifacts.short_path,
            "{APP_NAME}": erlang_info.app_name,
            "{TARGET_NAME}": ctx.label.name,
        },
        # deps = [files],
    )

    return [
        DefaultInfo(
            # files = inputs,
            runfiles = ctx.runfiles(files = [mix_release_artifacts]),
        )
    ]


mix_release = rule(
    implementation = _mix_release_impl,
    executable = True,
    attrs = {
        'app_name': attr.string(),
        'application': attr.label(providers = [MixProjectInfo, ErlangAppInfo]),
        "_template": attr.label(
            default = ":run_mix.tpl.sh",
            allow_single_file = True,
        ),
        "_hex_ez": attr.label(
            default = "@rules_elixir//private:hex-2.2.3-dev.ez",
            allow_files = [".ez"],
        ),
    },
    # TODO: demystify
    toolchains = ["//:toolchain_type"],
)

