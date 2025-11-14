"""Elixir-specific release information provider.

This provider extends release information with Elixir-specific details
like protocol consolidation and runtime configuration support.
"""

ElixirReleaseInfo = provider(
    doc = """Information about an Elixir release.

    This provider contains all information needed to work with an Elixir release,
    including references to the underlying Erlang release, Elixir-specific
    modifications (Config.Provider, consolidated protocols), and metadata.
    """,
    fields = {
        # Core release files (post-processed)
        "rel_file": """Path to .rel file (from erlang_release).
            This is the Erlang release specification file listing all applications.""",

        "script_file": """Path to processed .script file (with Elixir modifications).
            This script has Config.Provider injection and consolidated protocol paths added.""",

        "boot_file": """Path to processed .boot file (with Elixir modifications).
            This is the compiled binary version of the script file.""",

        "manifest_file": """EETF-encoded map of app_name -> version.
            Used to determine application versions for the bundle structure.""",

        # Erlang base information
        "erlang_release_info": """The underlying ErlangReleaseInfo provider.
            Contains the original Erlang release information before Elixir processing.""",

        # Elixir-specific additions
        "consolidated_protocols_dir": """Directory containing consolidated protocol beams.
            This is the output of elixir_protocol_consolidation rule. Will be None
            if protocol consolidation is not used.""",

        "sys_config_info": """SysConfigInfo provider from elixir_sys_config rule.
            Contains both compile-time and runtime configuration information.
            May be None if no sys.config is provided.""",

        "runtime_config_files": """List of runtime.exs files to include in the release.
            These are copied to releases/{version}/ directory and evaluated at runtime
            by Config.Provider.""",

        # Release metadata
        "release_name": """Name of the release.
            Used in file naming and directory structure.""",

        "release_version": """Version of the release.
            Used in directory structure and runtime paths.""",

        "app_name": """Name of the main application.
            The primary OTP application this release is built around.""",

        "env": """Build environment (prod, dev, test, staging).
            Affects configuration selection and compilation options.""",

        # Configuration flags
        "has_runtime_config": """Boolean: whether Config.Provider support is enabled.
            True if runtime configuration files are present and Config.Provider
            has been injected into the boot script.""",

        "has_consolidated_protocols": """Boolean: whether protocols are consolidated.
            True if protocol consolidation has been performed and consolidated
            beams are included in the release.""",

        # Original boot files (for debugging)
        "original_script_file": """Original .script file before Elixir modifications.
            Useful for debugging and comparing with processed version.""",

        "original_boot_file": """Original .boot file before Elixir modifications.
            Useful for debugging and comparing with processed version.""",
    },
)

def create_elixir_release_info(
        erlang_release_info,
        script_file,
        boot_file,
        original_script_file = None,
        original_boot_file = None,
        consolidated_protocols_dir = None,
        sys_config_info = None,
        runtime_config_files = None,
        env = "prod"):
    """Helper function to create ElixirReleaseInfo from ErlangReleaseInfo.

    This function takes the base Erlang release information and enhances it
    with Elixir-specific details.

    Args:
        erlang_release_info: ErlangReleaseInfo from erlang_release rule
        script_file: Processed .script file (output of boot_script_processor)
        boot_file: Processed .boot file (output of boot_script_processor)
        original_script_file: Original .script before processing (optional)
        original_boot_file: Original .boot before processing (optional)
        consolidated_protocols_dir: Optional consolidated protocols directory
        sys_config_info: Optional SysConfigInfo provider
        runtime_config_files: List of runtime config files to include (default: [])
        env: Build environment (default: "prod")

    Returns:
        ElixirReleaseInfo provider instance
    """
    # Handle default for runtime_config_files
    if runtime_config_files == None:
        runtime_config_files = []

    # Determine if runtime config is enabled
    has_runtime_config = False
    if sys_config_info != None and hasattr(sys_config_info, "has_runtime_config"):
        has_runtime_config = sys_config_info.has_runtime_config
    elif len(runtime_config_files) > 0:
        has_runtime_config = True

    # Determine if protocols are consolidated
    has_consolidated_protocols = consolidated_protocols_dir != None

    # Extract metadata from erlang_release_info
    # These fields should exist in ErlangReleaseInfo
    release_name = getattr(erlang_release_info, "release_name", "release")
    release_version = getattr(erlang_release_info, "release_version", "0.1.0")
    app_name = getattr(erlang_release_info, "app_name", release_name)

    return ElixirReleaseInfo(
        # Core files (processed versions)
        rel_file = erlang_release_info.rel_file,
        script_file = script_file,
        boot_file = boot_file,
        manifest_file = erlang_release_info.manifest_file,

        # Base info
        erlang_release_info = erlang_release_info,

        # Elixir additions
        consolidated_protocols_dir = consolidated_protocols_dir,
        sys_config_info = sys_config_info,
        runtime_config_files = runtime_config_files,

        # Metadata
        release_name = release_name,
        release_version = release_version,
        app_name = app_name,
        env = env,

        # Flags
        has_runtime_config = has_runtime_config,
        has_consolidated_protocols = has_consolidated_protocols,

        # Original files for debugging
        original_script_file = original_script_file if original_script_file else erlang_release_info.script_file,
        original_boot_file = original_boot_file if original_boot_file else erlang_release_info.boot_file,
    )