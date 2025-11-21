"""Functions for inferring configuration values from context.

These functions help reduce the need for explicit configuration by inferring
values from naming conventions, providers, and other contextual information.
"""

load(":release_info.bzl", "ReleaseInfo", "get_release_info")

def infer_env(ctx):
    """Infer the environment (prod/dev/test) from context.

    Inference order:
    1. Explicit env attribute if provided
    2. From ReleaseInfo provider if available
    3. From app_configs naming convention
    4. Default to "prod"

    Args:
        ctx: Rule context

    Returns:
        String: "prod", "dev", or "test"
    """
    # 1. Check explicit env attribute
    if hasattr(ctx.attr, "env") and ctx.attr.env:
        return ctx.attr.env

    # 2. Check ReleaseInfo provider
    release_info = get_release_info(ctx)
    if release_info:
        return release_info.env

    # 3. Infer from app_configs naming convention
    # This looks at the target names and file paths
    # TODO: Maybe we just make this required? We need to update a number of
    # other tools to not always assume `prod`...
    if hasattr(ctx.attr, "app_configs"):
        for config_target in ctx.attr.app_configs:
            # Check the target name (e.g., ":config_prod")
            target_name = str(config_target.label)
            if "config_prod" in target_name or "_prod" in target_name:
                return "prod"
            elif "config_dev" in target_name or "_dev" in target_name:
                return "dev"
            elif "config_test" in target_name or "_test" in target_name:
                return "test"

            # Also check file paths
            for config_file in config_target.files.to_list():
                path = config_file.path
                if "prod" in path:
                    return "prod"
                elif "dev" in path:
                    return "dev"
                elif "test" in path:
                    return "test"

    # 4. Default to prod
    return "prod"

def infer_version(ctx):
    """Infer the release version from context.

    Inference order:
    1. Explicit version attribute if provided
    2. From ReleaseInfo provider if available
    3. Default to "0.1.0"

    Args:
        ctx: Rule context

    Returns:
        String: Version string (e.g., "1.2.3")
    """
    # 1. Check explicit version attribute
    if hasattr(ctx.attr, "version") and ctx.attr.version:
        return ctx.attr.version

    # 2. Check ReleaseInfo provider
    release_info = get_release_info(ctx)
    if release_info:
        return release_info.version

    # 3. Default version
    return "0.1.0"

def infer_runtime_config_path(ctx):
    """Infer the runtime configuration path template.

    This creates an Erlang term template for locating runtime configuration
    at runtime, following Mix release conventions.

    Args:
        ctx: Rule context

    Returns:
        String: Erlang term template for runtime config path
    """
    # Check if explicit runtime_config_path is provided (for backward compat)
    if hasattr(ctx.attr, "runtime_config_path") and ctx.attr.runtime_config_path:
        return ctx.attr.runtime_config_path

    # Check ReleaseInfo provider
    release_info = get_release_info(ctx)
    if release_info and release_info.runtime_config_path:
        # Build the full path template using the release root template
        return '{{:system, "RELEASE_ROOT", "/{}"}}'.format(release_info.runtime_config_path)

    # Default to Mix convention with inferred version
    version = infer_version(ctx)
    return '{{:system, "RELEASE_ROOT", "/releases/{}/runtime.exs"}}'.format(version)

def infer_app_name(ctx):
    """Infer the OTP application name from context.

    Inference order:
    1. From ReleaseInfo provider if available
    2. From the target name
    3. From app_configs targets

    Args:
        ctx: Rule context

    Returns:
        String: Application name or None if cannot be inferred
    """
    # 1. Check ReleaseInfo provider
    release_info = get_release_info(ctx)
    if release_info:
        return release_info.app_name

    # 2. Try to infer from target name
    # Remove common suffixes like _sys_config, _config, etc.
    name = ctx.label.name
    for suffix in ["_sys_config", "_config", "_sys", "_cfg"]:
        if name.endswith(suffix):
            name = name[:-len(suffix)]
            break

    # If we have a reasonable name, return it
    if name and not name.startswith("_"):
        return name

    # 3. Try to infer from app_configs
    # This is less reliable but worth trying
    if hasattr(ctx.attr, "app_configs") and ctx.attr.app_configs:
        for config_target in ctx.attr.app_configs:
            target_name = config_target.label.name
            # Look for patterns like "myapp_config_prod"
            if "_config_" in target_name:
                parts = target_name.split("_config_")
                if parts[0]:
                    return parts[0]

    return None

def parse_config_provider_options(ctx):
    """Parse Config.Provider options from the config_provider_options dict.

    This converts the string dict attribute to proper boolean values with
    sensible defaults.

    Args:
        ctx: Rule context with config_provider_options attribute

    Returns:
        Dict with parsed options:
            - reboot_after_config: bool (default: False)
            - prune_after_boot: bool (default: True)
    """
    options = {
        "reboot_after_config": False,
        "prune_after_boot": True,
    }

    if hasattr(ctx.attr, "config_provider_options") and ctx.attr.config_provider_options:
        opts_dict = ctx.attr.config_provider_options

        # Parse reboot_after_config
        if "reboot_after_config" in opts_dict:
            value = opts_dict["reboot_after_config"].lower()
            options["reboot_after_config"] = value in ["true", "yes", "1", "on"]

        # Parse prune_after_boot
        if "prune_after_boot" in opts_dict:
            value = opts_dict["prune_after_boot"].lower()
            options["prune_after_boot"] = value in ["true", "yes", "1", "on"]

    return options

def should_use_runtime_config(ctx):
    """Determine if runtime configuration should be enabled.

    Args:
        ctx: Rule context

    Returns:
        Bool: True if runtime config should be used
    """
    # Check explicit runtime_configs attribute
    if hasattr(ctx.attr, "runtime_configs") and ctx.attr.runtime_configs:
        return True

    # Check ReleaseInfo provider
    release_info = get_release_info(ctx)
    if release_info:
        return release_info.has_runtime_config

    return False
