load(
    "@rules_erlang//private:erlang_build.bzl",
    "OtpInfo",
)
load(
    ":elixir_build.bzl",
    "ElixirInfo",
    "otp_install_snippet",
    "otp_runfiles",
)

def _elixir_source_build_impl(ctx):
    otp_info = ctx.attr.otp[OtpInfo]
    release_dir = ctx.actions.declare_directory("elixir_release")
    version_file = ctx.actions.declare_file("elixir_version")

    runfiles = otp_runfiles(ctx, otp_info)

    ctx.actions.run_shell(
        inputs = depset(
            direct = ctx.files.srcs,
            transitive = [runfiles.files],
        ),
        outputs = [release_dir],
        command = """set -euo pipefail

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

ABS_BUILD_DIR="$(mktemp -d)"
ABS_RELEASE_DIR=$PWD/{release_path}

# Copy source files preserving directory structure, using first file to determine prefix
mkdir -p $ABS_BUILD_DIR
REPO_PREFIX=$(dirname "{first_source_file}")
for src in {source_files}; do
  # Strip the repository prefix to get relative path from repository root
  relative_path=${{src#$REPO_PREFIX/}}
  dest_path=$ABS_BUILD_DIR/$relative_path
  mkdir -p "$(dirname "$dest_path")"
  cp "$src" "$dest_path"
done

echo "Building ELIXIR in $ABS_BUILD_DIR"
cd $ABS_BUILD_DIR

export HOME=$PWD

make

cp -r bin $ABS_RELEASE_DIR/
cp -r lib $ABS_RELEASE_DIR/
""".format(
            maybe_install_erlang = otp_install_snippet(otp_info),
            erlang_home = otp_info.erlang_home,
            release_path = release_dir.path,
            source_files = " ".join([f.path for f in ctx.files.srcs]),
            first_source_file = ctx.files.srcs[0].path if ctx.files.srcs else "",
        ),
        use_default_shell_env = True,
        mnemonic = "ELIXIRBUILD",
        progress_message = "Building Elixir from source",
    )

    ctx.actions.run_shell(
        inputs = depset(
            direct = [release_dir],
            transitive = [runfiles.files],
        ),
        outputs = [version_file],
        command = """set -euo pipefail

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

"{elixir_home}"/bin/iex --version > {version_file}
""".format(
            maybe_install_erlang = otp_install_snippet(otp_info),
            erlang_home = otp_info.erlang_home,
            elixir_home = release_dir.path,
            version_file = version_file.path,
        ),
        mnemonic = "ELIXIRVERSION",
        progress_message = "Validating elixir",
    )

    return [
        DefaultInfo(files = depset([release_dir, version_file])),
        otp_info,
        ElixirInfo(
            release_dir = release_dir,
            elixir_home = None,
            version_file = version_file,
        ),
    ]

elixir_source_build = rule(
    implementation = _elixir_source_build_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "otp": attr.label(
            mandatory = True,
            providers = [OtpInfo],
            doc = "An erlang_build target to use for compiling Elixir.",
        ),
    },
)
