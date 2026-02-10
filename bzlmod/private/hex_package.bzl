"""Simple hex package extension for rules_elixir.

This extension fetches hex packages with pre-resolved dependencies.
Dependency resolution is handled by external tooling.
"""

load("@rules_erlang//:hex_archive.bzl", "hex_archive")
load(":hex_pm.bzl", "hex_archive_url")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":common.bzl", "DEFAULT_BUILD_FILE_CONTENT", "format_deps_str")

def hex_package_repo(name, pkg, version, sha256, integrity, build_file, build_file_content, patches, patch_args, patch_cmds, explicit_deps=[]):
    """Create a hex_archive repository for a package."""
    package_name = pkg if pkg else name

    if build_file:
        if explicit_deps:
            fail("explicit_deps and build_file are mutually exclusive")
        hex_archive(
            name = name,
            package_name = package_name,
            version = version,
            sha256 = sha256,
            integrity = integrity,
            build_file = build_file,
            patches = patches,
            patch_args = patch_args,
            patch_cmds = patch_cmds,
        )
    elif build_file_content:
        if explicit_deps:
            fail("explicit_deps and build_file_content are mutually exclusive")

        hex_archive(
            name = name,
            package_name = package_name,
            version = version,
            sha256 = sha256,
            integrity = integrity,
            build_file_content = build_file_content,
            patches = patches,
            patch_args = patch_args,
            patch_cmds = patch_cmds,
        )
    else:
        # Generate default BUILD file for mix projects
        hex_archive(
            name = name,
            package_name = package_name,
            version = version,
            sha256 = sha256,
            integrity = integrity,
            build_file_content = DEFAULT_BUILD_FILE_CONTENT.format(
                app_name = package_name,
                explicit_deps_str = format_deps_str(explicit_deps),
            ),
            patches = patches,
            patch_args = patch_args,
            patch_cmds = patch_cmds,
        )

# Tag class for hex_package declarations
hex_package_tag = tag_class(attrs = {
    "name": attr.string(mandatory = True, doc = "Name of the package"),
    "pkg": attr.string(doc = "Package name on hex.pm (if different from name)"),
    "version": attr.string(mandatory = True, doc = "Version of the package"),
    "sha256": attr.string(doc = "Expected SHA256 of the package archive. Mutually exclusive with integrity."),
    "integrity": attr.string(doc = "Expected checksum in Subresource Integrity format. Mutually exclusive with sha256."),
    "build_file": attr.label(doc = "Custom BUILD file for the package"),
    "build_file_content": attr.string(doc = "Custom BUILD file content for the package"),
    "patches": attr.label_list(default = [], doc = "Patches to apply to the package"),
    "patch_args": attr.string_list(default = ["-p0"], doc = "Arguments for patch command"),
    "patch_cmds": attr.string_list(default = [], doc = "Shell commands to run after patching"),
    "explicit_deps": attr.label_list(default = [], doc = "Explicit hex_package-managed deps to use as dependencies for this package"),
})
