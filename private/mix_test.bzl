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

def _mix_test_impl(ctx):
    # Get providers from the lib dependency
    lib_erlang_info = ctx.attr.lib[ErlangAppInfo]
    lib_mix_info = ctx.attr.lib[MixProjectInfo]

    # Validate that lib was compiled with mix_env="test"
    if lib_mix_info.mix_env != "test":
        fail("mix_test requires a mix_library compiled with mix_env='test'. " +
             "Target '{}' was compiled with mix_env='{}'. ".format(ctx.attr.lib.label, lib_mix_info.mix_env) +
             "Create a separate mix_library with mix_env='test' for testing.")

    app_name = lib_erlang_info.app_name
    mix_config = lib_mix_info.mix_config

    # Get the ebin directory from the library
    lib_beam_dirs = lib_erlang_info.beam  # List containing the ebin directory
    lib_priv_dirs = lib_erlang_info.priv  # List containing the priv directory (if any)

    # Build ERL_LIBS for all dependencies (excluding the lib itself)
    erl_libs_dir = ctx.label.name + "_deps"
    lib_deps = lib_erlang_info.deps

    erl_libs_files = erl_libs_contents(
        ctx,
        dir = erl_libs_dir,
        deps = lib_deps,
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

    # Get the path to the lib's ebin directory
    # lib_beam_dirs is a list of File objects (directories)
    lib_ebin_path = ""
    if lib_beam_dirs:
        lib_ebin_path = lib_beam_dirs[0].short_path

    # Get the path to the lib's priv directory (if any)
    lib_priv_path = ""
    if lib_priv_dirs:
        lib_priv_path = lib_priv_dirs[0].short_path

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

# Navigate to the mix project root
cd "$TEST_SRCDIR/$TEST_WORKSPACE/{package}"

# Set up ERL_LIBS for dependencies
ERL_LIBS_PATH=""
if [[ -n "{erl_libs_path}" && -d "$TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path}" ]]; then
    ERL_LIBS_PATH="$(realpath $TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path})"
fi
export ERL_LIBS="$ERL_LIBS_PATH"

export HOME=/tmp
export MIX_HOME=/tmp/.mix
export MIX_ENV=test

{env}

{setup}

# Set up _build directory structure with pre-compiled artifacts
# This makes Mix think the project is already compiled
mkdir -p _build/test/lib/{app_name}/ebin

# Copy pre-compiled .beam and .app files from the mix_library
LIB_EBIN_PATH="$TEST_SRCDIR/$TEST_WORKSPACE/{lib_ebin_path}"
if [[ -d "$LIB_EBIN_PATH" ]]; then
    cp -r "$LIB_EBIN_PATH"/* _build/test/lib/{app_name}/ebin/
fi

# Copy priv directory if it exists
if [[ -n "{lib_priv_path}" ]]; then
    LIB_PRIV_PATH="$TEST_SRCDIR/$TEST_WORKSPACE/{lib_priv_path}"
    if [[ -d "$LIB_PRIV_PATH" ]]; then
        mkdir -p _build/test/lib/{app_name}/priv
        cp -r "$LIB_PRIV_PATH"/* _build/test/lib/{app_name}/priv/
    fi
fi

# Also set up dependency ebin directories in _build
if [[ -n "$ERL_LIBS_PATH" ]]; then
    for app_dir in "$ERL_LIBS_PATH"/*; do
        app_basename=$(basename "$app_dir")
        if [[ -d "$app_dir/ebin" ]]; then
            mkdir -p "_build/test/lib/$app_basename/ebin"
            cp -r "$app_dir/ebin"/* "_build/test/lib/$app_basename/ebin/"
        fi
        if [[ -d "$app_dir/priv" ]]; then
            mkdir -p "_build/test/lib/$app_basename/priv"
            cp -r "$app_dir/priv"/* "_build/test/lib/$app_basename/priv/"
        fi
    done
fi

# Build -pa options for each dependency's ebin directory
PA_OPTIONS="-pa _build/test/lib/{app_name}/ebin"
if [[ -n "$ERL_LIBS_PATH" ]]; then
    for app_dir in "$ERL_LIBS_PATH"/*; do
        if [[ -d "$app_dir/ebin" ]]; then
            PA_OPTIONS="$PA_OPTIONS -pa $app_dir/ebin"
        fi
    done
fi

# Run mix test with --no-compile to use pre-compiled artifacts
# Note: test/*.exs files are still compiled on-the-fly by ExUnit (this is by design)
MIX_ENV=test \\
    MIX_BUILD_ROOT=_build \\
    MIX_HOME=/tmp \\
    MIX_OFFLINE=true \\
    ELIXIR_ERL_OPTIONS="$PA_OPTIONS" \\
    ERL_LIBS="$ERL_LIBS_PATH" \\
    ${{ABS_ELIXIR_HOME}}/bin/mix test --no-compile --no-start --no-deps-check {test_paths} {mix_test_opts}
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        package = package,
        app_name = app_name,
        lib_ebin_path = lib_ebin_path,
        lib_priv_path = lib_priv_path,
        env = env,
        setup = ctx.attr.setup,
        test_paths = test_paths,
        mix_test_opts = " ".join([shell.quote(opt) for opt in ctx.attr.mix_test_opts]),
    )

    ctx.actions.write(
        output = output,
        content = script,
    )

    # Collect all files needed at runtime
    lib_files = []
    for beam_dir in lib_beam_dirs:
        lib_files.append(beam_dir)
    for priv_dir in lib_priv_dirs:
        lib_files.append(priv_dir)

    runfiles = erlang_runfiles.merge(elixir_runfiles)
    runfiles = runfiles.merge_all(
        [
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
            doc = "Optional list of specific test files to run. If empty, runs all tests in test/.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional data files needed for tests (include test/**/*.exs here)",
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
