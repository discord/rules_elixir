load(
    "@bazel_skylib//rules:common_settings.bzl",
    "BuildSettingInfo",
)
load(
    "@bazel_tools//tools/build_defs/repo:http.bzl",
    "http_archive",
)
load(
    "@rules_erlang//private:erlang_build.bzl",
    "OtpInfo",
)
load(
    "@rules_erlang//tools:erlang_toolchain.bzl",
    "erlang_home",
    "otp_rootdir_setup",
    "otp_runfiles",
)

ElixirInfo = provider(
    doc = "A Home directory of a built Elixir",
    fields = [
        "release_dir",
        "elixir_home",
        "version_file",
    ],
)

def elixir_version_action(ctx, otp_info, elixir_home, version_file, inputs, mnemonic = "ELIXIRVERSION", progress_message = "Validating elixir"):
    """Run `iex --version` to validate an Elixir install and capture its version.

    Shared by elixir_build / elixir_external / elixir_prebuilt / elixir_source_build:
    the command is identical; callers vary only in inputs, elixir_home, and labels.
    """
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [version_file],
        command = """set -euo pipefail

{erl_rootdir_setup}

export PATH="{erlang_home}"/bin:${{PATH}}

"{elixir_home}"/bin/iex --version > {version_file}
""".format(
            erl_rootdir_setup = otp_rootdir_setup(otp_info),
            erlang_home = erlang_home(otp_info),
            elixir_home = elixir_home,
            version_file = version_file.path,
        ),
        mnemonic = mnemonic,
        progress_message = progress_message,
    )

def _elixir_build_impl(ctx):
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

{erl_rootdir_setup}

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
            erl_rootdir_setup = otp_rootdir_setup(otp_info),
            erlang_home = erlang_home(otp_info),
            release_path = release_dir.path,
            source_files = " ".join([f.path for f in ctx.files.srcs]),
            first_source_file = ctx.files.srcs[0].path if ctx.files.srcs else "",
        ),
        use_default_shell_env = True,
        mnemonic = "ELIXIRBUILD",
        progress_message = "Building Elixir from source",
    )

    elixir_version_action(
        ctx,
        otp_info,
        release_dir.path,
        version_file,
        depset(direct = [release_dir], transitive = [runfiles.files]),
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

elixir_build = rule(
    implementation = _elixir_build_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "otp": attr.label(
            mandatory = True,
            providers = [OtpInfo],
            doc = "An erlang_build target to use for compiling Elixir.",
        ),
    },
)

def _elixir_external_impl(ctx):
    otp_info = ctx.attr.otp[OtpInfo]

    elixir_home = ctx.attr.elixir_home
    if elixir_home == "":
        elixir_home = ctx.attr._elixir_home[BuildSettingInfo].value

    version_file = ctx.actions.declare_file(ctx.label.name + "_version")

    runfiles = otp_runfiles(ctx, otp_info)

    elixir_version_action(
        ctx,
        otp_info,
        elixir_home,
        version_file,
        runfiles.files,
        mnemonic = "ELIXIR",
        progress_message = "Validating elixir at {}".format(elixir_home),
    )

    return [
        DefaultInfo(
            files = depset([version_file]),
        ),
        otp_info,
        ElixirInfo(
            release_dir = None,
            elixir_home = elixir_home,
            version_file = version_file,
        ),
    ]

elixir_external = rule(
    implementation = _elixir_external_impl,
    attrs = {
        "_elixir_home": attr.label(default = Label("//:elixir_home")),
        "elixir_home": attr.string(),
        "otp": attr.label(
            mandatory = True,
            providers = [OtpInfo],
            doc = "An erlang_build target providing the OTP installation.",
        ),
    },
)

def _archive_root(files):
    """Longest common directory prefix of all paths -- the extracted archive root.

    Stripping it makes a prebuilt Elixir's bin/ and lib/ land at the release_dir
    root. Robust regardless of glob ordering (unlike using the first file's dir).
    """

    # NOTE: Get the dirname of the first file to calculate the lowest common
    # path prefix between all files. Chopping off the last element ensures we
    # don't return the file itself, if we only have one file.
    # We always provide `files.srcs` here, so we should never be called with a directory.
    segs = files[0].path.split("/")[:-1]
    for f in files[1:]:
        other = f.path.split("/")
        n = 0
        for i in range(min(len(segs), len(other))):
            if segs[i] != other[i]:
                break
            n += 1
        segs = segs[:n]
    return "/".join(segs)

def _elixir_prebuilt_impl(ctx):
    otp_info = ctx.attr.otp[OtpInfo]
    release_dir = ctx.actions.declare_directory("elixir_release")
    version_file = ctx.actions.declare_file("elixir_version")

    runfiles = otp_runfiles(ctx, otp_info)

    # Stage the prebuilt Elixir release (bin/ + lib/) into a relocatable tree
    # artifact -- like elixir_build, but extract instead of `make`.
    ctx.actions.run_shell(
        inputs = ctx.files.srcs,
        outputs = [release_dir],
        command = """set -euo pipefail

ABS_RELEASE_DIR=$PWD/{release_path}
# cp -rp, not a tar -h pipe (cf. erlang_release_archive): compiled Elixir has no
# symlinks that need resolving. archive_root holds bin/ + lib/; /. copies contents.
cp -rp "{archive_root}/." "$ABS_RELEASE_DIR/"
""".format(
            release_path = release_dir.path,
            archive_root = _archive_root(ctx.files.srcs) if ctx.files.srcs else ".",
        ),
        mnemonic = "ELIXIRPREBUILT",
        progress_message = "Staging prebuilt Elixir",
    )

    elixir_version_action(
        ctx,
        otp_info,
        release_dir.path,
        version_file,
        depset(direct = [release_dir], transitive = [runfiles.files]),
        progress_message = "Validating prebuilt elixir",
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

elixir_prebuilt = rule(
    implementation = _elixir_prebuilt_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Extracted prebuilt Elixir release tree (bin/, lib/).",
        ),
        "otp": attr.label(
            mandatory = True,
            providers = [OtpInfo],
            doc = "An OTP target providing the installation to validate against.",
        ),
    },
)

def _elixir_prebuilt_tarball_impl(ctx):
    info = ctx.attr.elixir[ElixirInfo]
    if info.release_dir == None:
        fail("elixir_prebuilt_tarball requires a relocatable Elixir (release_dir set); " +
             "external installs (elixir_home) cannot be packaged.")

    tarball = ctx.actions.declare_file(ctx.label.name + ".tar.gz")

    ctx.actions.run_shell(
        inputs = [info.release_dir],
        outputs = [tarball],
        command = """set -euo pipefail

# -h dereferences symlinks so the archive has none (RBE-robust, matches
# rules_erlang's erlang_build). -C <dir> . puts bin/ + lib/ at the tar root,
# which is what internal_elixir_from_prebuilt / elixir_prebuilt expect.
tar -czhf "$PWD/{out}" -C "{release_dir}" .
""".format(
            out = tarball.path,
            release_dir = info.release_dir.path,
        ),
        use_default_shell_env = True,
        mnemonic = "ELIXIRTARBALL",
        progress_message = "Packaging prebuilt Elixir tarball",
    )

    return [DefaultInfo(files = depset([tarball]))]

elixir_prebuilt_tarball = rule(
    implementation = _elixir_prebuilt_tarball_impl,
    attrs = {
        "elixir": attr.label(
            mandatory = True,
            providers = [ElixirInfo],
            doc = "A target providing ElixirInfo (e.g. an elixir_build/elixir_prebuilt " +
                  "target such as @elixir_source_<name>//:elixir_build). Its release_dir " +
                  "(bin/ + lib/) is packaged into a .tar.gz for internal_elixir_from_prebuilt.",
        ),
    },
)
