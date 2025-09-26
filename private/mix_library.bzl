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
load("//private:mix_info.bzl", "MixProjectInfo")

def _elixir_erl_libs_args(paths):
    if not paths:
        return ""

    lib_dirs = " ".join(paths)
    return "-pa " + lib_dirs

def _mix_library_impl(ctx):
    # TODO: i don't _think_ we need to explicitly pass the output dir in, and
    # should instead return a Provider that can provide erlang...library info?
    # TBD
    # This also needs a better name
    ebin = ctx.actions.declare_directory("ebin")
    # app_file = ctx.actions.declare_file("{app_name}.app".format(app_name=ctx.attr.app_name))

    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = True,
        dir = erl_libs_dir,
        deps = flat_deps(ctx.attr.deps),
        # NOTE: even though we provide `ez_deps` here, these don't actually
        # correctly get added to our necessary include path. We explicitly set
        # MIX_ARCHIVES later to placate mix here.
        # TODO: improve this? it would be nice if we didn't have to do
        # explicit further handling for .ez files.
        ez_deps = ctx.files.ez_deps + ctx.files._hex_ez,
        expand_ezs = False,
    )

    # TODO:
    #  - confirm these are all as we expect
    #  - confirm if we need a secondary one of these for non-runtime deps
    #    (or maybe we just construct a combination classpath?)
    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        )

    # TODO: do we want to expose env vars here?
    env = ""
    # env = "\n".join([
    #     "export {}={}".format(k, v)
    #     for k, v in ctx.attr.env.items()
    # ])

    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    all_deps = flat_deps(ctx.attr.deps)

    script = """set -euo pipefail

{maybe_install_erlang}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

set +x

mkdir _output
export HOME=/tmp

# Save the original working directory before cd
ORIG_PWD="$PWD"

ls -laR {erl_libs_path}
ERL_LIBS_PATH="$(realpath {erl_libs_path})"

cd "{build_dir}"

# TODO: need to confirm deps are put into correct place here re: ERL_LIBS and
# ELIXIR_ERL_OPTIONS

MIX_ENV=prod \\
    MIX_BUILD_ROOT=_output \\
    MIX_HOME=/tmp \\
    MIX_OFFLINE=true \\
    ELIXIR_ERL_OPTIONS="-pa $ERL_LIBS_PATH" \\
    ERL_LIBS="$ERL_LIBS_PATH" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix compile --no-deps-check -mode embedded --no-elixir-version-check --skip-protocol-consolidation --no-optional-deps

# Use absolute path for output directory from original working directory
if [[ "{out_dir}" == /* ]]; then
    ABS_OUT_DIR="{out_dir}"
else
    ABS_OUT_DIR="$ORIG_PWD/{out_dir}"
fi

mkdir -p "$ABS_OUT_DIR"

# NOTE: this directory can contain files other than .app and .beam, but we only
# want to keep these in our build output.
cp _output/prod/lib/{app_name}/ebin/*.beam _output/prod/lib/{app_name}/ebin/*.app "$ABS_OUT_DIR/"
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        app_name = ctx.attr.app_name,
        # app_file_out = app_file.path,
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        build_dir = ctx.file.mix_config.dirname,
        name = ctx.label.name,
        # env = env,
        # setup = ctx.attr.setup,
        out_dir = ebin.path,
        # elixirc_opts = " ".join([shell.quote(opt) for opt in ctx.attr.elixirc_opts]),
        srcs = " ".join([f.path for f in ctx.files.srcs]),
    )

    inputs = depset(
        direct = ctx.files.srcs + ctx.files.data + erl_libs_files + [ctx.file.mix_config],
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
        ],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [ebin],
        command = script,
        mnemonic = "MIXCOMPILE",
    )

    return [
        DefaultInfo(
            files = depset([ebin]),
        ),
        MixProjectInfo(
            # app_name = ctx.attr.app_name,
            mix_config = ctx.file.mix_config,
            # ebin = '/'.join([ebin.path, 'ebin', 'lib', ctx.attr.app_name, 'ebin']),
            # TODO: should we actually keep this, or should be just YEET the
            # consolidated directory? it seems only have dependencies
            # (maybe we can just skip consolidation entirely??)
            # consolidated = '/'.join([ebin.path, 'ebin', 'lib', ctx.attr.app_name, 'consolidated']),

            # TODO: which of these approaches do we want to take here?
            #  1. we only keep the compiled BEAM files for _this_ library, and
            #    then combine _all_ dependencies in the `mix release` step
            #  2. we keep all BEAM files of all modules this depends on in the
            #    output, which will lead to bigger targets, but also means we
            #    might not have to carry the dep

            # i..._think_ we want to do 2 here -> need to confirm what gets
            # consolidated and what does not

            # TODO: this needs to maintain the full set of dependent libraries
            # needed to build this, if we want to avoid
            # deps = [ ],
        ),
        ErlangAppInfo(
            app_name = ctx.attr.app_name,
            # direct_deps = ctx.attr.deps,
            deps = all_deps,
            srcs = ctx.attr.srcs,
            # TODO: beam?
            beam = [ebin],
            # TODO: this is where we'll provide some of the weirder assets,
            # like .so files for NIFs.
            priv = [],
            # TODO: extra erlang libs to include?
            include = [],
            license_files = [],
            # I...don't think we use these here?
            extra_apps = [],
        ),
    ]

mix_library = rule(
    implementation = _mix_library_impl,
    attrs = {
        "app_name": attr.string(),
        "mix_config": attr.label(
            allow_single_file = [".exs"],
            default = ":mix.exs",
        ),
        "srcs": attr.label_list(
            allow_files = [".ex", ".erl"],
        ),
        "data": attr.label_list(
            allow_files = True,
        ),
        "deps": attr.label_list(
            # TODO: need to confirm the provider we create also outputs this
            providers = [ErlangAppInfo],
        ),
        # TODO: we should probably set a default for this?
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
        "_hex_ez": attr.label(
            default = "@rules_elixir//private:hex-2.2.3-dev.ez",
            allow_files = [".ez"],
        ),
        # "_vendored_deps": attr.label(
        #     default = "@rules_elixir//private:vendored_elixir_deps_src.tar.gz",
        #     allow_single_file = True,
        # ),
    },
    # TODO: confirm(??) (????)
    toolchains = ["//:toolchain_type"],
)
