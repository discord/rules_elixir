"""Simple hex package extension for rules_mix.

This extension fetches hex packages with pre-resolved dependencies.
Dependency resolution is handled by external tooling.
"""

load("@rules_erlang//:hex_archive.bzl", "hex_archive")
load(":hex_pm.bzl", "hex_archive_url")

def log(ctx, msg):
    """Log a message during extension execution."""
    ctx.execute(["echo", "RULES_ELIXIR: " + msg], timeout = 1, quiet = False)

def _hex_package_repo(name, pkg, version, sha256, build_file, build_file_content, patches, patch_args, patch_cmds):
    """Create a hex_archive repository for a package."""
    package_name = pkg if pkg else name

    if build_file:
        hex_archive(
            name = name,
            package_name = package_name,
            version = version,
            sha256 = sha256,
            build_file = build_file,
            patches = patches,
            patch_args = patch_args,
            patch_cmds = patch_cmds,
        )
    elif build_file_content:
        hex_archive(
            name = name,
            package_name = package_name,
            version = version,
            sha256 = sha256,
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
            build_file_content = DEFAULT_BUILD_FILE_CONTENT.format(
                app_name = package_name,
            ),
            patches = patches,
            patch_args = patch_args,
            patch_cmds = patch_cmds,
        )

def _elixir_packages_impl(module_ctx):
    """Implementation of the elixir_packages module extension."""
    packages = []

    # Collect all hex_package declarations from all modules
    for mod in module_ctx.modules:
        for dep in mod.tags.hex_package:
            if dep.build_file and dep.build_file_content:
                fail("build_file and build_file_content cannot be set simultaneously for {}".format(dep.name))
            packages.append({
                "name": dep.name,
                "pkg": dep.pkg,
                "version": dep.version,
                "sha256": dep.sha256,
                "build_file": dep.build_file,
                "build_file_content": dep.build_file_content,
                "patches": dep.patches,
                "patch_args": dep.patch_args,
                "patch_cmds": dep.patch_cmds,
                "module": mod,
            })

    # Simple deduplication by name - take the first occurrence
    # (External tooling should ensure no conflicts)
    seen = {}
    deduped = []
    for pkg in packages:
        if pkg["name"] not in seen:
            seen[pkg["name"]] = True
            deduped.append(pkg)
        else:
            log(module_ctx, "Duplicate package {} ignored (first occurrence wins)".format(pkg["name"]))

    if len(deduped) > 0:
        log(module_ctx, "Fetching {} hex packages:".format(len(deduped)))
        for pkg in deduped:
            log(module_ctx, "  {}@{}".format(pkg["name"], pkg["version"]))

    # Fetch all packages
    for pkg in deduped:
        _hex_package_repo(
            name = pkg["name"],
            pkg = pkg["pkg"],
            version = pkg["version"],
            sha256 = pkg["sha256"],
            build_file = pkg["build_file"],
            build_file_content = pkg["build_file_content"],
            patches = pkg["patches"],
            patch_args = pkg["patch_args"],
            patch_cmds = pkg["patch_cmds"],
        )

# Default BUILD file template for mix packages
DEFAULT_BUILD_FILE_CONTENT = """\
load("@rules_elixir//:defs.bzl", "mix_library")

package(default_visibility = ["//visibility:public"])

mix_library(
    name = "{app_name}",
    app_name = "{app_name}",
    srcs = glob([
        "lib/**/*.ex",
        "lib/**/*.exs",
    ], allow_empty = True),
    ez_deps = ["@rules_elixir//private:hex-2.2.3-dev.ez"],
    mix_config = ":mix.exs",
)
"""

# Tag class for hex_package declarations
hex_package_tag = tag_class(attrs = {
    "name": attr.string(mandatory = True, doc = "Name of the package"),
    "pkg": attr.string(doc = "Package name on hex.pm (if different from name)"),
    "version": attr.string(mandatory = True, doc = "Version of the package"),
    "sha256": attr.string(doc = "Expected SHA256 of the package archive"),
    "build_file": attr.label(doc = "Custom BUILD file for the package"),
    "build_file_content": attr.string(doc = "Custom BUILD file content for the package"),
    "patches": attr.label_list(default = [], doc = "Patches to apply to the package"),
    "patch_args": attr.string_list(default = ["-p0"], doc = "Arguments for patch command"),
    "patch_cmds": attr.string_list(default = [], doc = "Shell commands to run after patching"),
})

# The module extension
elixir_packages = module_extension(
    implementation = _elixir_packages_impl,
    tag_classes = {
        "hex_package": hex_package_tag,
    },
)
