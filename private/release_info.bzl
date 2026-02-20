"""Provider for sharing Mix release metadata across rules.

This provider allows release-related information to flow through the build graph,
enabling better inference and integration between rules like mix_release, elixir_sys_config,
and related tooling.
"""

# Define the ReleaseInfo provider
ReleaseInfo = provider(
    doc = """Information about a Mix/Elixir release.

    This provider shares release metadata that can be used by other rules to:
    - Infer configuration values (version, environment)
    - Coordinate release artifact generation
    - Share runtime paths and conventions
    """,
    fields = {
        "name": """The release name.

        This is the name of the release as it will appear in the generated
        artifacts. Typically matches the application name but can be customized.
        """,

        "version": """Release version File.

        A File containing the version string of this release, extracted
        from the release's start_erl.data during the build. Used to
        construct paths like /releases/{version}/sys.config at execution time.
        """,

        "env": """Build environment.

        The environment this release is built for: "prod", "dev", or "test".
        This affects which configuration files are used and how the release
        is optimized.
        """,

        "app_name": """The OTP application name.

        The name of the main OTP application in this release. This is used
        for application start commands and identifying the primary app.
        """,

        "release_root_template": """Path template for RELEASE_ROOT.

        An Erlang term template describing how to find the release root at
        runtime. Common values:
        - {:system, "RELEASE_ROOT", ""} - Use RELEASE_ROOT env var
        - "/opt/app" - Hardcoded path

        This is used to construct runtime configuration paths.
        """,

        "has_runtime_config": """Whether this release uses runtime configuration.

        Boolean indicating if this release includes runtime.exs or similar
        runtime configuration that requires Config.Provider support.
        """,

        "runtime_config_path": """Path to runtime configuration file.

        The path (relative to release root) where runtime configuration
        can be found. Typically "releases/{version}/runtime.exs" following
        Mix conventions.
        """,
    },
)

def create_release_info(
        name,
        version,
        env = "prod",
        app_name = None,
        release_root_template = '{:system, "RELEASE_ROOT", ""}',
        has_runtime_config = False,
        runtime_config_path = None):
    """Helper function to create a ReleaseInfo provider with defaults.

    Args:
        name: The release name
        version: File containing the release version string
        env: Build environment (default: "prod")
        app_name: OTP application name (default: same as name)
        release_root_template: Template for finding release root (default: RELEASE_ROOT env var)
        has_runtime_config: Whether runtime config is used (default: False)
        runtime_config_path: Path to runtime config (default: None; callers construct at execution time)

    Returns:
        ReleaseInfo provider instance
    """
    if not app_name:
        app_name = name

    return ReleaseInfo(
        name = name,
        version = version,
        env = env,
        app_name = app_name,
        release_root_template = release_root_template,
        has_runtime_config = has_runtime_config,
        runtime_config_path = runtime_config_path,
    )

def get_release_info(ctx):
    """Extract ReleaseInfo from a context's release attribute if present.

    Args:
        ctx: Rule context that may have a release attribute with ReleaseInfo

    Returns:
        ReleaseInfo provider or None if not present
    """
    if hasattr(ctx.attr, "release") and ctx.attr.release:
        if ReleaseInfo in ctx.attr.release:
            return ctx.attr.release[ReleaseInfo]
    return None