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
load("//private:mix_info.bzl", "MixProjectInfo")
load(":release_info.bzl", "ReleaseInfo", "create_release_info")

def _mix_release_impl(ctx):
    # TODO: run mix_release and output this

    erl_libs_dir = ctx.label.name + "_deps"

    erlang_info = ctx.attr.application[ErlangAppInfo]

    # Determine the release name and environment
    release_name = ctx.attr.release_name if ctx.attr.release_name else ctx.label.name
    app_name = ctx.attr.app_name if ctx.attr.app_name else erlang_info.app_name
    env = ctx.attr.env

    all_deps = [ctx.attr.application] + erlang_info.deps

    # NOTE: cargo-culted, needs further understanding
    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = True,
        dir = erl_libs_dir,
        deps = all_deps,
        # I don't think we ever need to add this in mix_release, because we'll
        # already have compiled all our deps into bytecode by this s       # point.
        ez_deps = [],
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
    extra_src_files = []
    for src in ctx.attr.configs:
        extra_src_files.extend(src[DefaultInfo].files.to_list())
    files = [app_config_file] + extra_src_files
    if erlang_info.beam:
        files.extend(erlang_info.beam)

    runfiles = ctx.runfiles(files = files)

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    mix_release_artifacts = ctx.actions.declare_directory("{}_release".format(ctx.label.name))
    version_file = ctx.actions.declare_file("{}_version.txt".format(ctx.label.name))
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
export HEX_OFFLINE=true


mkdir -p "$OUTPUT_DIR/{env}/lib"
for app_dir in "$ERL_LIBS_PATH"/*; do
    if [ -d "$app_dir/ebin" ]; then
        app_name=$(basename "$app_dir")
        mkdir -p "$OUTPUT_DIR/{env}/lib/$app_name/ebin"
        cp -r "$app_dir/ebin"/* "$OUTPUT_DIR/{env}/lib/$app_name/ebin/"
    fi
done

# Build -pa options for each dependency's ebin directory
PA_OPTIONS=""
if [[ -n "$ERL_LIBS_PATH" ]]; then
    for app_dir in "$ERL_LIBS_PATH"/*; do
        if [[ -d "$app_dir/ebin" ]]; then
            PA_OPTIONS="$PA_OPTIONS -pa $app_dir/ebin"
        fi
    done
fi

MIX_ENV={env} \\
    MIX_BUILD_ROOT="$OUTPUT_DIR" \\
    HOME=/tmp \\
    MIX_HOME=/tmp \\
    ELIXIR_ERL_OPTIONS="$PA_OPTIONS" \\
    ERL_LIBS="$ERL_LIBS_PATH" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix release --no-compile --no-deps-check

cd -
mv $OUTPUT_DIR/{env}/rel/{app_name} {output_file}
awk '{{print $2}}' {output_file}/releases/start_erl.data | tr -d '\\n' > {version_file}
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        elixir_home = elixir_home,
        erlang_home = erlang_home,
        erl_libs_path = erl_libs_path,
        # I think these should be provided via a runfiles struct....right?
        build_dir = app_config_file.dirname,
        app_name = app_name,
        env = env,
        output_file = mix_release_artifacts.path,
        version_file = version_file.path,
    )

    # TODO: need to make this uh, better and less cargo-culty
    inputs = depset(
        direct = files + erl_libs_files,
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
        ],
    )

    # this takes all the BEAM files, and outputs a new directory that has all
    # the outputs combines. The output is needed to build the executable
    # script
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [mix_release_artifacts, version_file],
        command = script,
        mnemonic = "MIXRELEASE",
    )

    # TODO: confirm if we _actually_ need this
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = ctx.outputs.executable,
        is_executable = True,
        substitutions = {
            "{BINARY_PATH}": mix_release_artifacts.short_path,
            "{APP_NAME}": erlang_info.app_name,
            "{TARGET_NAME}": ctx.label.name,
            "{COMMAND_LINE_ARGS}": " ".join(ctx.attr.command_line_args),
            "{RUN_ARGUMENT}": ctx.attr.run_argument,
        },
        # deps = [files],
    )

    # Create ReleaseInfo provider
    release_info = create_release_info(
        name = release_name,
        version = version_file,
        env = env,
        app_name = app_name,
        # TODO: i think mix just gives us this for free?
        has_runtime_config = ctx.attr.sys_config != None if hasattr(ctx.attr, "sys_config") else False,
    )

    return [
        DefaultInfo(
            # files = inputs,
            runfiles = ctx.runfiles(files = [mix_release_artifacts]),
        ),
        release_info,
    ]

mix_release = rule(
    implementation = _mix_release_impl,
    executable = True,
    attrs = {
        # Existing attributes
        "app_name": attr.string(
            doc = "Override the application name (defaults to ErlangAppInfo.app_name)",
        ),
        "application": attr.label(
            providers = [MixProjectInfo, ErlangAppInfo],
            doc = "The Mix application to create a release for",
        ),
        "configs": attr.label_list(
            # Mix configuration files are only evaluated at release time, and
            # get bundled into the end artifact. Thus, we need to accept these
            # _here_, and not at compile time.
            doc = """Configuration files to accept during build.

            Note that all can be provided here, regardless of environment, mix will
            selectively evaluate the config specific to the specified mix env.
            """,
            allow_files = [".exs"],
        ),
        "run_argument": attr.string(
            default = "start",
            doc = "The default command to run (start, daemon, etc.)",
        ),
        "command_line_args": attr.string_list(
            default = [],
            doc = "Additional command line arguments to pass to the release",
        ),
        "env": attr.string(
            default = "prod",
            values = ["prod", "dev", "test", "staging"],
            doc = """Build environment for the release.

            Affects:
            - Which configuration files are used
            - Compilation optimizations
            - Runtime behavior
            """,
        ),
        "release_name": attr.string(
            doc = """Override the release name.

            Defaults to the target name. This is the name that appears
            in the generated release artifacts and commands.
            """,
        ),
        "sys_config": attr.label(
            doc = """Optional sys.config target.

            If provided, uses this sys.config for the release.
            Future: Will auto-generate if not provided.
            """,
        ),

        # Internal
        "_template": attr.label(
            default = ":run_mix.tpl.sh",
            allow_single_file = True,
        ),
    },
    provides = [DefaultInfo, ReleaseInfo],
    # TODO: demystify
    toolchains = ["//:toolchain_type"],
)
