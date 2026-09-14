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
load(
    ":hermetic_tar.bzl",
    "TAR_TOOLCHAIN_TYPE",
    "archive_cmds",
    "bsdtar_setup",
    "mtree_cmds",
)

# The build directory path ends up inside Elixir's own outputs -- elixirc
# records the source path in the compile info of every .beam it writes -- so
# it has to be a constant. A `mktemp -d` here made the tarball differ between
# two builds of the same target. rules_erlang solved this first; this keeps
# its shape and uses this module's own name, so that a cleanup of
# /tmp/rules_elixir_build never touches an OTP build.
_BUILD_ROOT_PREFIX = "/tmp/rules_elixir_build"

# The fixed path is the price of reproducibility (see _BUILD_ROOT_PREFIX).
# Two builds of this target at once on an unsandboxed machine would share it,
# so the lock turns that into a loud error instead of two makes in one tree.
# The rm is the other half: we always start empty, so a run that died
# mid-build can never be silently resumed. Bazel never cleans /tmp, so we
# remove the tree on the way out too.
_BUILD_ROOT_SETUP = """\
BUILD_ROOT="{build_root}"
BUILD_LOCK="$BUILD_ROOT.lock"
mkdir -p "{build_root_prefix}"
if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
    echo "ERROR: $BUILD_ROOT is already in use by another build."
    echo "       If no other build is running, remove $BUILD_LOCK and retry."
    exit 1
fi
trap 'rm -rf "$BUILD_ROOT" "$BUILD_LOCK"' EXIT
rm -rf "$BUILD_ROOT"
ABS_BUILD_DIR="$BUILD_ROOT"
mkdir -p "$ABS_BUILD_DIR"\
"""

def build_root_setup(ctx, otp_info):
    """Shell that takes the lock on this build's fixed build directory.

    Args:
        ctx: the rule context. Its label name and `version` attribute key the
            directory, so that two Elixir builds do not collide.
        otp_info: the OtpInfo of the OTP this build runs against. Its version
            keys the directory too, because the same Elixir source built
            against two OTP versions is two builds.

    Returns:
        Shell commands that set ABS_BUILD_DIR, ready to interpolate.
    """
    key = "-".join([
        ctx.label.name,
        ctx.attr.version or "unversioned",
        "otp" + (otp_info.version or "unknown"),
    ]).replace("/", "_")
    return _BUILD_ROOT_SETUP.format(
        build_root = _BUILD_ROOT_PREFIX + "/" + key,
        build_root_prefix = _BUILD_ROOT_PREFIX,
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

ABS_RELEASE_DIR=$PWD/{release_path}

# elixir_prebuilt_tarball records the mode of every file it packages, and the
# cp below takes its modes from the action's umask. Bazel does not set one,
# so without this line a worker on anything but 022 produces a different
# tarball for the same Elixir.
umask 022

{build_root_setup}

# Copy source files preserving directory structure, using first file to determine prefix
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
            build_root_setup = build_root_setup(ctx, otp_info),
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
        "version": attr.string(
            doc = "The Elixir version these sources hold. It keys the fixed " +
                  "build directory, so two versions can build at the same " +
                  "time. Only that; nothing validates it.",
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

    # Output name is derived from the target name (cf. rules_erlang's
    # erlang_build). The elixir_config extension names the target after the
    # Elixir + OTP install identifiers, so hosted runtimes are distinguishable
    # (e.g. elixir-1_16-otp26_2.tar.gz).
    tarball = ctx.actions.declare_file(ctx.label.name + ".tar.gz")

    tar_toolchain = ctx.toolchains[TAR_TOOLCHAIN_TYPE]
    bsdtar = tar_toolchain.tarinfo.binary

    ctx.actions.run_shell(
        inputs = [info.release_dir],
        outputs = [tarball],
        command = """set -euo pipefail

ABS_OUT="$PWD/{out}"

{bsdtar_setup}

# The manifest goes to a scratch file, not into the release directory: pass 2
# archives everything the release directory holds at that moment.
MTREE="$(mktemp)"
trap 'rm -f "$MTREE"' EXIT

# -h dereferences symlinks so the archive has none (RBE-robust, matches
# rules_erlang's erlang_build). cd <dir> then `.` puts bin/ + lib/ at the tar
# root, which is what internal_elixir_from_prebuilt / elixir_prebuilt expect.
# The old command was a bare `tar -czhf`, which wrote the wall clock, the
# builder's uid and the output filename into the archive, so the same Elixir
# never gave the same sha256 twice. gzip -n keeps the last of those three out
# of the gzip header; private/hermetic_tar.bzl handles the rest.
cd "{release_dir}"
{mtree_cmds}
{archive_cmds} | gzip -n > "$ABS_OUT"
""".format(
            out = tarball.path,
            release_dir = info.release_dir.path,
            bsdtar_setup = bsdtar_setup(tar_toolchain, bsdtar.path),
            mtree_cmds = mtree_cmds("-h .", "$MTREE"),
            archive_cmds = archive_cmds("$MTREE"),
        ),
        tools = tar_toolchain.default.files,
        toolchain = TAR_TOOLCHAIN_TYPE,
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
    toolchains = [TAR_TOOLCHAIN_TYPE],
)
