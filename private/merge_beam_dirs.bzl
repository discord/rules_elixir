load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")

def _impl(ctx):
    """Merge multiple beam directories into a single ebin directory."""
    out = ctx.actions.declare_directory(ctx.attr.dest)

    # Build the copy commands for each beam directory
    copy_commands = []
    for beam_dir in ctx.files.beam_dirs:
        if beam_dir.is_directory:
            # Copy all files from the directory
            copy_commands.append('cp -r "{}/"* "{}" 2>/dev/null || true'.format(beam_dir.path, out.path))
        else:
            # If it's a file (shouldn't happen with directories), copy it directly
            copy_commands.append('cp "{}" "{}"'.format(beam_dir.path, out.path))

    # Build the complete shell command
    command = """set -euo pipefail
mkdir -p "{out}"
{copy_commands}
cp "{app_file}" "{out}/"
""".format(
        out = out.path,
        copy_commands = "\n".join(copy_commands),
        app_file = ctx.file.app_file.path,
    )

    # Execute the merge
    ctx.actions.run_shell(
        inputs = ctx.files.beam_dirs + [ctx.file.app_file],
        outputs = [out],
        command = command,
        mnemonic = "MERGEBEAM",
    )

    # Prepare dependencies
    deps = flat_deps(ctx.attr.deps) if ctx.attr.deps else []

    # Create runfiles
    runfiles = ctx.runfiles(files = [out] + ctx.files.priv)
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    return [
        ErlangAppInfo(
            app_name = ctx.attr.app_name,
            extra_apps = ctx.attr.extra_apps,
            include = ctx.files.hdrs,
            beam = [out],
            priv = ctx.files.priv,
            license_files = ctx.files.license_files,
            srcs = ctx.files.srcs,
            deps = deps,
        ),
        DefaultInfo(
            files = depset([out]),
            runfiles = runfiles,
        ),
    ]

merge_beam_dirs = rule(
    implementation = _impl,
    attrs = {
        "beam_dirs": attr.label_list(
            doc = "List of directories containing .beam files to merge",
            allow_files = True,
            mandatory = True,
        ),
        "app_file": attr.label(
            doc = "The .app file for the application",
            allow_single_file = [".app"],
            mandatory = True,
        ),
        "dest": attr.string(
            doc = "Name of the output directory",
            default = "ebin",
        ),
        # ErlangAppInfo fields
        "app_name": attr.string(
            doc = "Name of the Erlang application",
            mandatory = True,
        ),
        "extra_apps": attr.string_list(
            doc = "Extra applications to include",
            default = [],
        ),
        "hdrs": attr.label_list(
            doc = "Header files",
            allow_files = [".hrl"],
            default = [],
        ),
        "srcs": attr.label_list(
            doc = "Source files",
            allow_files = [".erl", ".ex"],
            default = [],
        ),
        "priv": attr.label_list(
            doc = "Private files",
            allow_files = True,
            default = [],
        ),
        "license_files": attr.label_list(
            doc = "License files",
            allow_files = True,
            default = [],
        ),
        "deps": attr.label_list(
            doc = "Dependencies",
            providers = [ErlangAppInfo],
            default = [],
        ),
    },
    provides = [ErlangAppInfo],
)
