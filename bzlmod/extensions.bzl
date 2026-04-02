load(
    "@bazel_tools//tools/build_defs/repo:http.bzl",
    "http_archive",
)
load(
    "//bzlmod/private:elixir_packages.bzl",
    _elixir_packages = "elixir_packages",
)
load(
    "//repositories:elixir_config.bzl",
    "INSTALLATION_TYPE_EXTERNAL",
    "INSTALLATION_TYPE_INTERNAL",
    _elixir_config_rule = "elixir_config",
)

DEFAULT_ELIXIR_VERSION = "1.15.0"
DEFAULT_ELIXIR_SHA256 = "0f4df7574a5f300b5c66f54906222cd46dac0df7233ded165bc8e80fd9ffeb7a"

def _elixir_config(ctx):
    # Resolve the canonical repo name for @erlang_config so we can reference
    # it from generated http_archive repos (which don't have it in their
    # repo mapping). We use Label().repo_name per Bazel docs rather than
    # hardcoding the canonical name format.
    erlang_config_repo = Label("@erlang_config").repo_name

    types = {}
    versions = {}
    urls = {}
    strip_prefixs = {}
    sha256s = {}
    elixir_homes = {}
    target_compatible_withs = {}
    exec_compatible_withs = {}

    for mod in ctx.modules:
        for elixir in mod.tags.external_elixir_from_path:
            types[elixir.name] = INSTALLATION_TYPE_EXTERNAL
            versions[elixir.name] = elixir.version
            elixir_homes[elixir.name] = elixir.elixir_home
            target_compatible_withs[elixir.name] = [str(l) for l in elixir.target_compatible_with]
            exec_compatible_withs[elixir.name] = [str(l) for l in elixir.exec_compatible_with]


        for elixir in mod.tags.internal_elixir_from_http_archive:
            types[elixir.name] = INSTALLATION_TYPE_INTERNAL
            versions[elixir.name] = elixir.version
            urls[elixir.name] = elixir.url
            strip_prefixs[elixir.name] = elixir.strip_prefix
            sha256s[elixir.name] = elixir.sha256
            target_compatible_withs[elixir.name] = [str(l) for l in elixir.target_compatible_with]
            exec_compatible_withs[elixir.name] = [str(l) for l in elixir.exec_compatible_with]

            # Create repository for downloading and building Elixir source.
            # The http_archive repo doesn't have @erlang_config in its repo
            # mapping, so we use the canonical name resolved above.
            http_archive(
                name = "elixir_source_{}".format(elixir.name),
                url = elixir.url,
                sha256 = elixir.sha256,
                strip_prefix = elixir.strip_prefix,
                build_file_content = """
load("@rules_elixir//private:elixir_build.bzl", "elixir_build")

elixir_build(
    name = "elixir_build",
    srcs = glob(["**/*"]),
    otp = "@@{erlang_config_repo}//{otp}:otp-{otp}",
    visibility = ["//visibility:public"],
)
""".format(
                    erlang_config_repo = erlang_config_repo,
                    otp = elixir.otp,
                ),
            )

        for elixir in mod.tags.internal_elixir_from_github_release:
            url = "https://github.com/elixir-lang/elixir/archive/refs/tags/v{}.tar.gz".format(
                elixir.version,
            )
            strip_prefix = "elixir-{}".format(elixir.version)

            types[elixir.name] = INSTALLATION_TYPE_INTERNAL
            versions[elixir.name] = elixir.version
            urls[elixir.name] = url
            strip_prefixs[elixir.name] = strip_prefix
            sha256s[elixir.name] = elixir.sha256
            target_compatible_withs[elixir.name] = [str(l) for l in elixir.target_compatible_with]
            exec_compatible_withs[elixir.name] = [str(l) for l in elixir.exec_compatible_with]

            # Create repository for downloading and building Elixir source.
            # The http_archive repo doesn't have @erlang_config in its repo
            # mapping, so we use the canonical name resolved above.
            http_archive(
                name = "elixir_source_{}".format(elixir.name),
                url = url,
                sha256 = elixir.sha256,
                strip_prefix = strip_prefix,
                build_file_content = """
load("@rules_elixir//private:elixir_build.bzl", "elixir_build")

elixir_build(
    name = "elixir_build",
    srcs = glob(["**/*"]),
    otp = "@@{erlang_config_repo}//{otp}:otp-{otp}",
    visibility = ["//visibility:public"],
)
""".format(
                    erlang_config_repo = erlang_config_repo,
                    otp = elixir.otp,
                ),
            )

    _elixir_config_rule(
        name = "elixir_config",
        types = types,
        versions = versions,
        urls = urls,
        strip_prefixs = strip_prefixs,
        sha256s = sha256s,
        elixir_homes = elixir_homes,
        exec_compatible_withs = exec_compatible_withs,
        target_compatible_withs = target_compatible_withs,
    )

external_elixir_from_path = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "elixir_home": attr.string(),
    # It doesn't...really make sense to have an exec_compatible_with for an
    # extenral toolchain that's already on the host?
    "exec_compatible_with": attr.label_list(default = []),
    "target_compatible_with": attr.label_list(default = []),
})

internal_elixir_from_http_archive = tag_class(attrs = {
    "name": attr.string(),
    "version": attr.string(),
    "url": attr.string(),
    "strip_prefix": attr.string(),
    "sha256": attr.string(),
    "otp": attr.string(
        mandatory = True,
        doc = "Name of an erlang_config installation to use for building Elixir (e.g. '25_bootstrap').",
    ),
    "exec_compatible_with": attr.label_list(default = []),
    "target_compatible_with": attr.label_list(default = []),
})

internal_elixir_from_github_release = tag_class(attrs = {
    "name": attr.string(
        default = "internal",
    ),
    "version": attr.string(
        default = DEFAULT_ELIXIR_VERSION,
    ),
    "sha256": attr.string(
        default = DEFAULT_ELIXIR_SHA256,
    ),
    "otp": attr.string(
        mandatory = True,
        doc = "Name of an erlang_config installation to use for building Elixir (e.g. '25_bootstrap').",
    ),
    # NOTE: these should default to the host platform
    "exec_compatible_with": attr.label_list(default = []),
    "target_compatible_with": attr.label_list(default = []),
})

elixir_config = module_extension(
    implementation = _elixir_config,
    tag_classes = {
        "external_elixir_from_path": external_elixir_from_path,
        "internal_elixir_from_http_archive": internal_elixir_from_http_archive,
        "internal_elixir_from_github_release": internal_elixir_from_github_release,
    },
)

# Re-export the elixir_packages extension
elixir_packages = _elixir_packages
