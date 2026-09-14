"""A test that the bsdtar pipeline of private/hermetic_tar.bzl is
reproducible, and that it agrees with the canonical GNU tar flag set.

Why a rule rather than an sh_test with a checked-in script? The script has to
hold the exact pipeline elixir_prebuilt_tarball runs, or it protects nothing.
This rule builds the script from the same Starlark strings, so the two cannot
drift. A checked-in fixture would not work either: Bazel resolves a source
symlink on its way into the runfiles tree, and a symlink is one of the three
shapes under test, so the script builds the fixture itself.
"""

load(
    "//private:hermetic_tar.bzl",
    "TAR_TOOLCHAIN_TYPE",
    "archive_cmds",
    "bsdtar_setup",
    "mtree_cmds",
)

def _tar_repro_test_impl(ctx):
    tar_toolchain = ctx.toolchains[TAR_TOOLCHAIN_TYPE]
    bsdtar = tar_toolchain.tarinfo.binary

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        is_executable = True,
        substitutions = {
            # short_path reaches an external file as ../<repo>/..., which the
            # kernel resolves against the runfiles directory the test runs in.
            "%{BSDTAR_SETUP}": bsdtar_setup(tar_toolchain, bsdtar.short_path),
            "%{MTREE_CMDS}": mtree_cmds("-h .", "$MTREE"),
            "%{ARCHIVE_CMDS}": archive_cmds("$MTREE"),
        },
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(transitive_files = tar_toolchain.default.files),
    )]

tar_repro_test = rule(
    implementation = _tar_repro_test_impl,
    attrs = {
        "_template": attr.label(
            default = Label("//tar_repro:tar_repro_test.sh.tpl"),
            allow_single_file = True,
        ),
    },
    test = True,
    toolchains = [TAR_TOOLCHAIN_TYPE],
)
