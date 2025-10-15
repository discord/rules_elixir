load("@bazel_tools//tools/build_defs/repo:git.bzl", "new_git_repository")
load(":common.bzl", "DEFAULT_BUILD_FILE_CONTENT", "format_deps_str")

def git_package_repo(name, remote="", repository="", branch="", tag="", commit="",
                      build_file=None, build_file_content="", patch_cmds=[], testonly=False,
                      strip_prefix="", explicit_deps=[]):
    """Create a git repository for a package."""

    # Handle repository vs remote
    if remote and repository:
        fail("'remote' and 'repository' are mutually exclusive")

    if repository:
        actual_remote = "https://github.com/{}.git".format(repository)
    elif remote:
        actual_remote = remote
    else:
        fail("either 'remote' or 'repository' is required")

    # Determine the app name
    app_name = name

    if build_file:
        if explicit_deps:
            fail("explicit_deps and build_file are mutually exclusive")
        new_git_repository(
            name = name,
            remote = actual_remote,
            branch = branch,
            tag = tag,
            commit = commit,
            build_file = build_file,
            patch_cmds = patch_cmds,
            strip_prefix = strip_prefix,
        )
    elif build_file_content:
        if explicit_deps:
            fail("explicit_deps and build_file_content are mutually exclusive")

        new_git_repository(
            name = name,
            remote = actual_remote,
            branch = branch,
            tag = tag,
            commit = commit,
            build_file_content = build_file_content,
            patch_cmds = patch_cmds,
            strip_prefix = strip_prefix,
        )
    else:
        # Use default BUILD file for mix projects
        new_git_repository(
            name = name,
            remote = actual_remote,
            branch = branch,
            tag = tag,
            commit = commit,
            build_file_content = DEFAULT_BUILD_FILE_CONTENT.format(
                app_name = app_name,
                explicit_deps_str = format_deps_str(explicit_deps),
            ),
            patch_cmds = patch_cmds,
            strip_prefix = strip_prefix,
        )


git_package_tag = tag_class(attrs = {
    "name": attr.string(doc = "Name of the package"),
    "remote": attr.string(doc = "Git remote URL"),
    "repository": attr.string(doc = "GitHub repository in format 'owner/repo'"),
    "branch": attr.string(default = "", doc = "Git branch"),
    "tag": attr.string(default = "", doc = "Git tag"),
    "commit": attr.string(default = "", doc = "Git commit SHA"),
    "build_file": attr.label(doc = "Custom BUILD file for the package"),
    "build_file_content": attr.string(doc = "Custom BUILD file content for the package"),
    "patch_cmds": attr.string_list(default = [], doc = "Shell commands to run after fetching"),
    "testonly": attr.bool(default = False, doc = "Mark as testonly"),
    "explicit_deps": attr.label_list(default = [], doc = "Explicit hex_package-managed deps to use as dependencies for this package"),
    "strip_prefix": attr.string(default = "", doc="Prefix to strip from repository")
})
