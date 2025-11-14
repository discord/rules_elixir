load(":git_package.bzl", "git_package_tag", "git_package_repo")
load(":hex_package.bzl", "hex_package_tag", "hex_package_repo")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def log(ctx, msg):
    """Log a message during extension execution."""
    ctx.execute(["echo", "RULES_ELIXIR: " + msg], timeout = 1, quiet = False)

def _elixir_packages_impl(module_ctx):
    """Implementation of the elixir_packages module extension."""

    # Always provide hex_pm repository automatically
    # This ensures hex is available as a dependency for all mix_library targets
    http_archive(
        name = "hex_pm",
        urls = ["https://github.com/hexpm/hex/archive/refs/tags/v2.2.2.tar.gz"],
        strip_prefix = "hex-2.2.2",
        sha256 = "f3ba423f2937eb593eccc863c060f147af333e188620b7879ceb4e3b97faf07c",
        build_file_content = """
load("@rules_elixir//:mix_library.bzl", "mix_library")

mix_library(
    name = "lib",
    app_name = "hex",
    srcs = glob(["src/*.erl", "src/*.xrl", "src/*.hrl", "lib/**/*.ex"]),
    data = ["lib/hex/http/ca-bundle.crt"],
    mix_config = ":mix.exs",
    visibility = ["//visibility:public"],
)
""",
    )

    packages = []

    # NOTE: need to also tack in git_pacakge here

    # Collect all hex_package declarations from all modules
    for mod in module_ctx.modules:
        for dep in mod.tags.git_package:
            # TODO: perhaps we should do some deduplication here, similar to
            # what we're doing with hexpm-sourced repos?

            git_package_repo(
                name = dep.name,
                remote = dep.remote,
                repository = dep.repository,
                branch = dep.branch,
                tag = dep.tag,
                commit = dep.commit,
                build_file = dep.build_file,
                build_file_content = dep.build_file_content,
                patch_cmds = dep.patch_cmds,
                testonly = dep.testonly,
                strip_prefix = dep.strip_prefix,
            )

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
        hex_package_repo(
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


# The module extension
elixir_packages = module_extension(
    implementation = _elixir_packages_impl,
    tag_classes = {
        "hex_package": hex_package_tag,
        "git_package": git_package_tag,
    },
)
