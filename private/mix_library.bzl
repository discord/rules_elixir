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

def _priv_file_dest_relative_path(label, f):
    """Calculate the relative path for a priv file, preserving directory structure.

    Strips the 'priv/' prefix if present, since files are typically glob'd as 'priv/**/*'
    but should be placed directly in the priv output directory.
    """
    if label.workspace_root != "":
        workspace_root = label.workspace_root.replace("external/", "../")
        rel_base = path_join(workspace_root, label.package)
    else:
        rel_base = label.package
    if rel_base != "":
        rel_path = f.short_path.replace(rel_base + "/", "")
    else:
        rel_path = f.short_path

    # Strip 'priv/' prefix if present (common when using glob(['priv/**/*']))
    if rel_path.startswith("priv/"):
        rel_path = rel_path[len("priv/"):]

    return rel_path

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
    priv_dir = ctx.actions.declare_directory("priv") if ctx.files.priv else None
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
        ez_deps = ctx.files.ez_deps,
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

    priv_copy_commands = ""
    priv_copy_to_build_dir = ""
    if priv_dir:
        # Commands to copy priv files to build directory (for Mix to access during compilation)
        priv_copy_to_build_dir = "\n# Copy priv files to build directory for Mix access\n"
        for priv_file in ctx.files.priv:
            rel_path = _priv_file_dest_relative_path(ctx.label, priv_file)
            priv_copy_to_build_dir += "    mkdir -p \"priv/$(dirname {})\"\n".format(rel_path)
            # Only copy if source and destination are different (avoid "same file" errors)
            priv_copy_to_build_dir += "    if [[ \"$ORIG_PWD/{}\" != \"$(pwd)/priv/{}\" ]]; then\n".format(
                priv_file.path,
                rel_path
            )
            priv_copy_to_build_dir += "        cp -L \"$ORIG_PWD/{}\" \"priv/{}\"\n".format(
                priv_file.path,
                rel_path
            )
            priv_copy_to_build_dir += "    fi\n"

        # Commands to copy priv files to output directory (for ErlangAppInfo provider)
        priv_copy_commands = "\n# Copy priv files to output directory preserving directory structure\n"
        priv_copy_commands += "mkdir -p \"$ABS_OUT_PRIV_DIR\"\n"

        for priv_file in ctx.files.priv:
            rel_path = _priv_file_dest_relative_path(ctx.label, priv_file)
            priv_copy_commands += "mkdir -p \"$ABS_OUT_PRIV_DIR/$(dirname {})\"\n".format(rel_path)
            priv_copy_commands += "cp -L \"$ORIG_PWD/{}\" \"$ABS_OUT_PRIV_DIR/{}\"\n".format(
                priv_file.path,
                rel_path
            )

    # TODO: confirm if we need to use include dir from other modules, or if
    # that's just a way for elixir to expose and interface to erlang.
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

ERL_LIBS_PATH=""
if [[ -n "{erl_libs_path}" ]]
then
    ERL_LIBS_PATH="$(realpath {erl_libs_path})"
fi

cd "{build_dir}"

# Copy priv files into build directory BEFORE compilation
# This makes them available to Mix tasks, NIFs, etc. during compilation
if [[ -n "{priv_out_dir}" ]]; then
    mkdir -p priv
{priv_copy_to_build_dir}
fi

# TODO: need to confirm deps are put into correct place here re: ERL_LIBS and
# ELIXIR_ERL_OPTIONS

export VERSION="deadbeef"

# Build -pa options for each dependency's ebin directory
PA_OPTIONS=""
if [[ -n "$ERL_LIBS_PATH" ]]; then
    for app_dir in "$ERL_LIBS_PATH"/*; do
        if [[ -d "$app_dir/ebin" ]]; then
            PA_OPTIONS="$PA_OPTIONS -pa $app_dir/ebin"
        fi
    done
fi

MIX_ENV=prod \\
    MIX_BUILD_ROOT=_output \\
    MIX_HOME=/tmp \\
    MIX_OFFLINE=true \\
    ELIXIR_ERL_OPTIONS="$PA_OPTIONS" \\
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

# Set priv output directory if priv files exist
if [[ -n "{priv_out_dir}" ]]; then
    if [[ "{priv_out_dir}" == /* ]]; then
        ABS_OUT_PRIV_DIR="{priv_out_dir}"
    else
        ABS_OUT_PRIV_DIR="$ORIG_PWD/{priv_out_dir}"
    fi
    {priv_copy_commands}
fi
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
        priv_out_dir = priv_dir.path if priv_dir else "",
        priv_copy_to_build_dir = priv_copy_to_build_dir,
        priv_copy_commands = priv_copy_commands,
        # elixirc_opts = " ".join([shell.quote(opt) for opt in ctx.attr.elixirc_opts]),
        srcs = " ".join([f.path for f in ctx.files.srcs]),
    )

    inputs = depset(
        direct = ctx.files.srcs + ctx.files.data + ctx.files.include + ctx.files.priv + erl_libs_files + [ctx.file.mix_config],
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
        ],
    )

    outputs = [ebin]
    if priv_dir:
        outputs.append(priv_dir)

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outputs,
        command = script,
        mnemonic = "MIXCOMPILE",
    )

    output_files = [ebin]
    priv_files = []
    if priv_dir:
        output_files.append(priv_dir)
        priv_files = [priv_dir]

    return [
        DefaultInfo(
            files = depset(output_files),
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
            # Priv files with preserved directory structure
            priv = priv_files,
            # TODO: extra erlang libs to include?
            include = ctx.files.include,
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
            # TODO: is there a more comprehensive place I can find all
            # supported extensions than just adding them as I find them? There
            # are a lot of weird extensions...
            allow_files = [".ex", ".erl", ".xrl", ".hrl", ".app.src"],
        ),
        "data": attr.label_list(
            allow_files = True,
        ),
        "deps": attr.label_list(
            # TODO: need to confirm the provider we create also outputs this
            providers = [ErlangAppInfo],
        ),
        "priv": attr.label_list(
            allow_files = True,
        ),
        "include": attr.label_list(
            allow_files = [".hrl"],
        ),
        # TODO: we should probably set a default for this?
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
    },
    # TODO: confirm(??) (????)
    toolchains = ["//:toolchain_type"],
)
