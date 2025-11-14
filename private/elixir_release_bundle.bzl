"""Elixir release bundle rule for creating deployable release bundles.

## What This Rule Does

The `elixir_release_bundle` rule creates a complete, deployable OTP release bundle
following standard OTP conventions, with Elixir-specific additions:

**Standard OTP structure**:
```
bundle/
├── bin/{app_name}              # Startup script
├── lib/{app}-{version}/
│   ├── ebin/                  # Compiled BEAM files
│   └── priv/                  # Private resources
├── releases/{version}/
│   ├── start.boot             # Boot file
│   ├── sys.config             # System configuration
│   └── {release_name}.rel     # Release specification
└── erts-{version}/            # ERTS (if include_erts is True)
```

**Elixir-specific additions**:
```
releases/{version}/
├── consolidated/              # Consolidated protocols (Elixir-only)
│   └── Elixir.Enumerable.beam
├── runtime.exs                # Runtime configuration (Elixir-only)
└── ...
```

## How It Works

### Phase 1: Create Base OTP Bundle Structure
1. Creates standard OTP directory layout (bin/, lib/, releases/)
2. Copies processed release files from `elixir_release` (.rel, .script, .boot, .manifest)
3. Copies sys.config if provided
4. Collects all application BEAM and priv files from the dependency graph

### Phase 2: Add Elixir-Specific Artifacts
1. **Consolidated Protocols**: If protocol consolidation was performed, copies the
   consolidated protocol directory to `releases/{version}/consolidated/`. Protocol
   consolidation is an Elixir optimization not applicable to pure Erlang.

2. **Runtime Configuration**: If runtime config files are provided (typically
   `runtime.exs`), copies them to `releases/{version}/`. These are evaluated at
   application startup via Config.Provider.

### Phase 3: Generate Enhanced Startup Script
Creates a startup script at `bin/{release_name}` with:
- RELEASE_ROOT, RELEASE_LIB, RELEASE_VSN environment variable setup
- Command modes: start (daemon), console (interactive), foreground
- Automatic ERTS detection (bundled vs system)
- sys.config path resolution
- Proper ERL_CMD invocation with boot arguments

The startup script is more sophisticated than basic erlang_release_bundle scripts,
providing better environment variable setup needed for Config.Provider.

### Phase 4: Optional ERTS Inclusion
If `include_erts = True`, bundles the Erlang Runtime System making the release
self-contained and runnable without a system Erlang installation.

## How It Diverges from erlang_release_bundle

rules_erlang_2 provides `erlang_release_bundle` which creates standard OTP bundles.
rules_elixir provides this separate rule because:

### Differences

| Aspect                     | erlang_release_bundle | elixir_release_bundle        |
|----------------------------|-----------------------|------------------------------|
| **Input**                  | ErlangReleaseInfo     | ElixirReleaseInfo            |
| **Consolidated protocols** | Not supported         | Copies consolidated/ dir     |
| **Runtime config**         | Not supported         | Copies runtime.exs files     |
| **Startup script**         | Basic erl invocation  | Enhanced with RELEASE_* vars |
| **Config.Provider**        | N/A                   | Environment properly set up  |

### Why Not Reuse erlang_release_bundle?

Making use of erlang_release_bundle here would have required adding elixir-specific options
(e.g., consolidated_dir, runtime_configs) that break the desired abstraction boundary. While
this does have some slightly duplicated logic, it should be pretty stable.

"""

load("@rules_erlang//:erlang_release.bzl", "ErlangReleaseInfo")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")
load("//private:elixir_release_info.bzl", "ElixirReleaseInfo")
load("//private:elixir_sys_config.bzl", "SysConfigInfo")
load(
    "//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _impl(ctx):
    """Implementation of elixir_release_bundle rule."""

    elixir_release_info = ctx.attr.release[ElixirReleaseInfo]
    erlang_release_info = elixir_release_info.erlang_release_info

    release_name = elixir_release_info.release_name
    release_version = elixir_release_info.release_version

    # Declare output directory
    bundle_dir = ctx.actions.declare_directory("{}_bundle".format(ctx.label.name))

    # Get Erlang toolchain
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    # Collect all input files
    # Note: script_file and boot_file are now a directory containing the processed files
    input_files = [
        erlang_release_info.rel_file,
        elixir_release_info.script_file,  # This is the release directory
        erlang_release_info.manifest_file,
    ]

    # Add sys.config if present
    sys_config_file = None
    if elixir_release_info.sys_config_info:
        sys_config_file = elixir_release_info.sys_config_info.sys_config
        input_files.append(sys_config_file)

    # Add runtime config files if present
    runtime_configs = elixir_release_info.runtime_config_files
    if runtime_configs:
        input_files.extend(runtime_configs)

    # Add consolidated protocols if present
    consolidated_dir = elixir_release_info.consolidated_protocols_dir

    # Collect all app infos including the main app and its dependencies
    app_info = erlang_release_info.app_info
    all_app_infos = [app_info]

    # Add all dependencies
    for dep in app_info.deps:
        if ErlangAppInfo in dep:
            all_app_infos.append(dep[ErlangAppInfo])

    # Collect beam and priv files from all apps
    for app_info_dep in all_app_infos:
        input_files.extend(app_info_dep.beam)
        if hasattr(app_info_dep, "priv"):
            input_files.extend(app_info_dep.priv)

    # Generate processing script for each app
    app_processing_lines = []
    for app_info_dep in all_app_infos:
        app_name = app_info_dep.app_name

        # Generate copy commands for beam files
        beam_copy_commands = []
        for f in app_info_dep.beam:
            if f.is_directory:
                beam_copy_commands.append('    cp -r "{}"/* "$APP_DIR/ebin/" 2>/dev/null || true'.format(f.path))
            else:
                beam_copy_commands.append('    cp "{}" "$APP_DIR/ebin/"'.format(f.path))

        # Generate copy commands for priv files
        priv_copy_commands = []
        if hasattr(app_info_dep, "priv") and app_info_dep.priv:
            priv_copy_commands.append('    mkdir -p "$APP_DIR/priv"')
            for f in app_info_dep.priv:
                if f.is_directory:
                    priv_copy_commands.append('    cp -r "{}/"* "$APP_DIR/priv/" 2>/dev/null || true'.format(f.path))
                else:
                    priv_copy_commands.append('    cp "{}" "$APP_DIR/priv/"'.format(f.path))

        app_processing_lines.append("""
# Process {app_name}
APP_VERSION=$("{erlang_home}"/bin/erl -noshell -eval '
    {{ok, Binary}} = file:read_file("'$MANIFEST_FILE'"),
    Map = binary_to_term(Binary),
    Version = maps:get({app_name}, Map, <<"0.0.0">>),
    io:format("~s", [Version]),
    halt().' 2>/dev/null || echo "0.0.0")

if [ -n "$APP_VERSION" ]; then
    APP_DIR="$BUNDLE_DIR/lib/{app_name}-$APP_VERSION"
    mkdir -p "$APP_DIR/ebin"

    # Copy beam files
{beam_copies}

    # Copy priv files if they exist
{priv_copies}

    echo "  Copied {app_name}-$APP_VERSION"
fi
""".format(
            app_name = app_name,
            erlang_home = erlang_home,
            beam_copies = "\n".join(beam_copy_commands) if beam_copy_commands else "    # No beam files",
            priv_copies = "\n".join(priv_copy_commands) if priv_copy_commands else "    # No priv files",
        ))

    # Generate sys.config copy commands
    sys_config_copy = ""
    if sys_config_file:
        sys_config_copy = """
echo "Copying sys.config..."
cp "{sys_config}" "$BUNDLE_DIR/releases/$RELEASE_VERSION/sys.config"
""".format(sys_config = sys_config_file.path)

    # Generate runtime config copy commands
    runtime_config_copy = ""
    if runtime_configs:
        runtime_config_lines = ['echo "Copying runtime config files..."']
        for config in runtime_configs:
            runtime_config_lines.append('cp "{}" "$BUNDLE_DIR/releases/$RELEASE_VERSION/"'.format(config.path))
        runtime_config_copy = "\n".join(runtime_config_lines)

    # Generate consolidated protocols copy command
    consolidated_copy = ""
    if consolidated_dir:
        input_files.append(consolidated_dir)
        consolidated_copy = """
echo "Copying consolidated protocols..."
mkdir -p "$BUNDLE_DIR/releases/$RELEASE_VERSION/consolidated"
cp -r "{consolidated_dir}"/* "$BUNDLE_DIR/releases/$RELEASE_VERSION/consolidated/" 2>/dev/null || true
""".format(consolidated_dir = consolidated_dir.path)

    # Generate startup script
    startup_script = """
cat > "$BUNDLE_DIR/bin/$RELEASE_NAME" << 'EOF'
#!/bin/sh
set -e

# Find release root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_ROOT="$(dirname "$SCRIPT_DIR")"

export RELEASE_ROOT
export RELEASE_NAME="{release_name}"
export RELEASE_VSN="{release_version}"
export RELEASE_LIB="$RELEASE_ROOT/lib"

# Default command
COMMAND="${{1:-{startup_command}}}"
shift || true

# Determine boot arguments based on command
case "$COMMAND" in
    start|daemon)
        BOOT_ARGS="-detached -noinput"
        ;;
    console)
        BOOT_ARGS=""
        ;;
    foreground)
        BOOT_ARGS="-noshell -noinput"
        ;;
    *)
        echo "Usage: $0 [start|daemon|console|foreground] [args...]"
        exit 1
        ;;
esac

# Check for ERTS
ERTS_DIR=""
if [ -d "$RELEASE_ROOT/erts-"* ]; then
    ERTS_DIR=$(ls -d "$RELEASE_ROOT"/erts-* | head -1)
    ERL_CMD="$ERTS_DIR/bin/erl"
else
    # Use system Erlang
    ERL_CMD="erl"
fi

# Build sys.config argument
SYS_CONFIG=""
if [ -f "$RELEASE_ROOT/releases/$RELEASE_VSN/sys.config" ]; then
    SYS_CONFIG="-config $RELEASE_ROOT/releases/$RELEASE_VSN/sys"
fi

# Start the release
exec "$ERL_CMD" \\
    -boot "$RELEASE_ROOT/releases/$RELEASE_VSN/start" \\
    $SYS_CONFIG \\
    -mode embedded \\
    {command_line_args} \\
    $BOOT_ARGS \\
    "$@"
EOF

chmod +x "$BUNDLE_DIR/bin/$RELEASE_NAME"
""".format(
        release_name = release_name,
        release_version = release_version,
        startup_command = ctx.attr.startup_command,
        command_line_args = " \\\n    ".join([
            '"{}"'.format(arg) for arg in ctx.attr.command_line_args
        ]) if ctx.attr.command_line_args else "",
    )

    # Build the complete bundle creation script
    script = """set -euo pipefail

{maybe_install_erlang}

BUNDLE_DIR="{bundle_dir}"
MANIFEST_FILE="{manifest_file}"
RELEASE_NAME="{release_name}"
RELEASE_VERSION="{release_version}"

echo "Creating Elixir release bundle..."
echo "  Release: $RELEASE_NAME v$RELEASE_VERSION"

# Create directory structure
mkdir -p "$BUNDLE_DIR/bin"
mkdir -p "$BUNDLE_DIR/releases/$RELEASE_VERSION"

# Copy release files from the Elixir release directory
echo "Copying release files..."
# The elixir_release_dir contains processed .rel, .script, .boot, and .manifest files
cp "{elixir_release_dir}"/*.rel "$BUNDLE_DIR/releases/$RELEASE_VERSION/" 2>/dev/null || cp "{rel_file}" "$BUNDLE_DIR/releases/$RELEASE_VERSION/"
cp "{elixir_release_dir}"/*.script "$BUNDLE_DIR/releases/$RELEASE_VERSION/"
cp "{elixir_release_dir}"/*.boot "$BUNDLE_DIR/releases/$RELEASE_VERSION/start.boot"
cp "{elixir_release_dir}"/*.manifest "$BUNDLE_DIR/releases/$RELEASE_VERSION/" 2>/dev/null || cp "{manifest_file}" "$BUNDLE_DIR/releases/$RELEASE_VERSION/"

# Copy sys.config if present
{sys_config_copy}

# Copy runtime config files if present
{runtime_config_copy}

# Copy consolidated protocols if present
{consolidated_copy}

# Process all applications
echo "Processing applications..."
{app_processing}

# Generate startup script
echo "Generating startup script..."
mkdir -p "$BUNDLE_DIR/bin"
{startup_script}

# Include ERTS if requested
{include_erts}

echo ""
echo "Bundle created successfully at $BUNDLE_DIR"
echo "  Applications: $(find "$BUNDLE_DIR/lib" -maxdepth 1 -type d | tail -n +2 | wc -l) apps"
{consolidated_message}
{runtime_config_message}
echo ""
echo "To start the release:"
echo "  $BUNDLE_DIR/bin/$RELEASE_NAME start    # Start as daemon"
echo "  $BUNDLE_DIR/bin/$RELEASE_NAME console  # Start with console"
echo "  $BUNDLE_DIR/bin/$RELEASE_NAME foreground  # Start in foreground"
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        bundle_dir = bundle_dir.path,
        manifest_file = erlang_release_info.manifest_file.path,
        release_name = release_name,
        release_version = release_version,
        rel_file = erlang_release_info.rel_file.path,
        elixir_release_dir = elixir_release_info.script_file.path,  # This is the directory now
        sys_config_copy = sys_config_copy,
        runtime_config_copy = runtime_config_copy,
        consolidated_copy = consolidated_copy,
        app_processing = "\n".join(app_processing_lines),
        startup_script = startup_script,
        include_erts = _generate_erts_inclusion(ctx, erlang_home) if ctx.attr.include_erts else "# ERTS not included",
        consolidated_message = 'echo "  Protocols: Consolidated"' if consolidated_dir else "",
        runtime_config_message = 'echo "  Runtime config: Enabled"' if runtime_configs else "",
    )

    # Run the bundle creation
    ctx.actions.run_shell(
        inputs = depset(
            direct = input_files,
            transitive = [erlang_runfiles.files],
        ),
        outputs = [bundle_dir],
        command = script,
        mnemonic = "ElixirReleaseBundle",
        progress_message = "Creating Elixir release bundle for {}".format(release_name),
    )

    return [
        DefaultInfo(
            files = depset([bundle_dir]),
            runfiles = ctx.runfiles(files = [bundle_dir]),
        ),
    ]

def _generate_erts_inclusion(ctx, erlang_home):
    """Generate script to include ERTS in the bundle."""
    if ctx.attr.erts_path:
        erts_source = ctx.attr.erts_path
    else:
        # Use ERTS from the toolchain
        erts_source = erlang_home

    return """
echo "Including ERTS..."
if [ -d "{erts_source}/erts-"* ]; then
    ERTS_DIR=$(ls -d "{erts_source}"/erts-* | head -1)
    ERTS_VERSION=$(basename "$ERTS_DIR")
    echo "  Copying $ERTS_VERSION..."
    cp -r "$ERTS_DIR" "$BUNDLE_DIR/"

    # Make binaries executable
    chmod +x "$BUNDLE_DIR/$ERTS_VERSION/bin/"*
else
    echo "  Warning: ERTS not found at {erts_source}"
fi
""".format(erts_source = erts_source)

elixir_release_bundle = rule(
    implementation = _impl,
    attrs = {
        # --- Core Attributes ---

        "release": attr.label(
            mandatory = True,
            providers = [ElixirReleaseInfo],
            doc = """The elixir_release target to bundle.

            This should be a target created by elixir_release rule.

            Example:
                release = ":my_release"
            """,
        ),

        # --- Bundle Configuration ---

        "include_erts": attr.bool(
            default = False,
            doc = """Whether to include ERTS (Erlang Runtime System) in the bundle.

            When True, the bundle is self-contained and can run without an
            installed Erlang/OTP. Increases bundle size significantly.

            When False, requires OTP to be installed on the target system.

            Default: False
            """,
        ),

        "erts_path": attr.string(
            doc = """Path to ERTS to include when include_erts is True.

            If not specified, uses ERTS from the toolchain.

            Example:
                erts_path = "/usr/local/lib/erlang"
            """,
        ),

        # --- Startup Configuration ---

        "startup_command": attr.string(
            default = "start",
            values = ["start", "daemon", "console", "foreground"],
            doc = """Default startup mode for the release.

            - start: Start as a daemon (background)
            - daemon: Same as start (alias)
            - console: Start with an interactive console
            - foreground: Start in foreground without console

            Default: "start"
            """,
        ),

        "command_line_args": attr.string_list(
            default = [],
            doc = """Additional command-line arguments for the VM.

            These are passed to the Erlang VM at startup.

            Example:
                command_line_args = ["+P", "1000000", "+Q", "65536"]
            """,
        ),
    },
    provides = [DefaultInfo],
    toolchains = ["//:toolchain_type"],
    doc = """Create a deployable Elixir release bundle.

    This rule creates a complete OTP release bundle with Elixir-specific additions:

    Bundle structure:
        bin/
            {app_name}              # Startup script
        lib/
            {app}-{version}/
                ebin/              # Compiled BEAM files
                priv/              # Private resources
        releases/
            {version}/
                consolidated/      # Consolidated protocols (if present)
                runtime.exs       # Runtime config (if present)
                start.boot        # Processed boot file
                sys.config        # System configuration
                {release_name}.rel     # Release specification
                {release_name}.script  # Boot script
        erts-{version}/           # ERTS directory (if include_erts is True)

    Example:
        elixir_release_bundle(
            name = "my_bundle",
            release = ":my_release",
            include_erts = True,
            startup_command = "foreground",
        )

    The bundle can be started with:
        ./my_bundle/bin/{app_name} start     # Start as daemon
        ./my_bundle/bin/{app_name} console   # Start with console
        ./my_bundle/bin/{app_name} foreground # Start in foreground
    """,
)
