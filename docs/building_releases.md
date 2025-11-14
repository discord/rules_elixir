# Building Elixir Release Bundles: A Complete Guide

This guide explains the complete process of building a deployable Elixir release bundle from source code using rules_mix. We'll walk through each step of the pipeline, from compiling bytecode to creating a production-ready bundle.

## Overview

Building an Elixir release bundle involves several stages:

1. **Compile bytecode** - Build your application and generate BEAM files with app metadata
2. **Consolidate protocols** (optional) - Pre-compile protocol implementations for faster startup
3. **Generate configuration** - Create sys.config for runtime configuration
4. **Create release** - Generate OTP release files (.rel, .script, .boot)
5. **Bundle release** - Package everything into a deployable directory structure

```
Source Code
    ↓
[mix_library or elixir_app]
    ↓
Bytecode + ErlangAppInfo
    ↓
[protocol_consolidation] (optional)
    ↓
Consolidated Protocols
    ↓
[elixir_sys_config] (optional)
    ↓
Configuration Files
    ↓
[elixir_release]
    ↓
Release Files (.rel, .script, .boot)
    ↓
[elixir_release_bundle]
    ↓
Deployable Bundle
```

---

## Step 1: Building Application Bytecode

The first step is compiling your Elixir/Erlang code into BEAM bytecode and generating the necessary application metadata. You have two options depending on your project structure.

### Option A: Using `mix_library` (Recommended for Mix Projects)

`mix_library` is designed for projects with a `mix.exs` file. It uses Mix's compiler to build your application while integrating with Bazel's dependency management.

**Basic Example:**

```starlark
load("@rules_mix//:defs.bzl", "mix_library")

mix_library(
    name = "my_app",
    srcs = glob([
        "lib/**/*.ex",
        "lib/**/*.exs",
    ]),
    mix_config = "mix.exs",
    deps = [
        "@hex_jason//:jason",
        "@hex_plug//:plug",
    ],
)
```

**Key Attributes:**

- `srcs`: Your Elixir source files (typically `lib/**/*.ex`)
- `mix_config`: Path to your `mix.exs` file
- `deps`: Bazel dependencies (Hex packages, other mix_library targets, etc.)
- `beam`: Additional pre-compiled BEAM files to include
- `priv`: Private resources (templates, static files, etc.)

**What it produces:**

- Compiled BEAM files in an `ebin/` directory
- Generated `.app` file with application metadata
- `ErlangAppInfo` provider containing all app metadata and dependencies

### Option B: Using `elixir_app` (Lower-level Alternative)

`elixir_app` gives you more control over the compilation process. Use this when:
- You don't have a `mix.exs` file
- You want finer control over compiler options
- You're building a library without Mix dependencies

**Basic Example:**

```starlark
load("@rules_mix//:defs.bzl", "elixir_app")

elixir_app(
    name = "my_app",
    srcs = glob(["lib/**/*.ex"]),
    app_name = "my_app",
    app_version = "1.0.0",
    deps = [
        "@hex_jason//:jason",
    ],
)
```

**Key Attributes:**

- `srcs`: Elixir source files to compile
- `app_name`: Application name (must match your module prefix)
- `app_version`: Version string
- `deps`: Dependencies providing `ErlangAppInfo`
- `erlc_opts`: Compiler options passed to `elixirc`

**What it produces:**

- Same outputs as `mix_library`: BEAM files, `.app` file, `ErlangAppInfo` provider

### Choosing Between mix_library and elixir_app

| Use Case | Recommended Rule |
|----------|------------------|
| Standard Mix project with mix.exs | `mix_library` |
| Need Mix compiler features | `mix_library` |
| No mix.exs file | `elixir_app` |
| Building a simple library | `elixir_app` |
| Need fine-grained compiler control | `elixir_app` |

---

## Step 2: Protocol Consolidation (Optional but Recommended)

Protocol consolidation pre-compiles all protocol implementations, significantly improving application startup time. This is especially important for production releases.

### What Protocol Consolidation Does

In Elixir, protocols (like `Enumerable`, `String.Chars`, etc.) are dispatched at runtime by checking which implementations exist. Consolidation:

1. Finds all protocol implementations across your app and dependencies
2. Compiles them into a single dispatch table
3. Eliminates runtime lookups, making protocol dispatch much faster

### Adding Protocol Consolidation

```starlark
load("@rules_mix//:defs.bzl", "mix_library", "protocol_consolidation")

mix_library(
    name = "my_app",
    srcs = glob(["lib/**/*.ex"]),
    mix_config = "mix.exs",
    deps = [
        "@hex_jason//:jason",
        "@hex_plug//:plug",
    ],
)

protocol_consolidation(
    name = "consolidated_protocols",
    app = ":my_app",
)
```

**What it produces:**

- A directory of consolidated protocol BEAM files
- `ProtocolConsolidationInfo` provider for use in the release

**Important Notes:**

- Consolidation must run **after** all dependencies are compiled
- The consolidated directory will be copied to `releases/{version}/consolidated/` in the bundle
- The boot script is automatically modified to add the consolidated path to the code path

---

## Step 3: Configuration with sys.config

System configuration provides compile-time and runtime settings for your application and OTP libraries.

### Basic sys.config

```starlark
load("@rules_mix//:defs.bzl", "elixir_sys_config")

elixir_sys_config(
    name = "sys_config_prod",
    src = "config/prod.exs",
    env = "prod",
    app = ":my_app",
)
```

### With Runtime Configuration

For runtime-configurable releases (using `config/runtime.exs`):

```starlark
elixir_sys_config(
    name = "sys_config_prod",
    src = "config/config.exs",
    runtime_src = "config/runtime.exs",
    env = "prod",
    app = ":my_app",
)
```

**Key Attributes:**

- `src`: Main configuration file (typically `config/prod.exs` or `config/config.exs`)
- `runtime_src`: Runtime configuration file (optional, for `Config.Provider` support)
- `env`: Environment name ("prod", "dev", "test", "staging")
- `app`: Your application target

**What it produces:**

- `sys.config` file in Erlang term format
- `SysConfigInfo` provider with runtime config metadata
- Optionally, runtime configuration files to be included in the bundle

For more details, see [sys_config_generation.md](./sys_config_generation.md).

---

## Step 4: Creating the Release with elixir_release

`elixir_release` generates the OTP release files and adds Elixir-specific boot script modifications.

### How elixir_release Works

Under the hood, `elixir_release`:

1. **Calls `erlang_release`** from rules_erlang to generate base release files using SASL's `systools:make_script/2`
2. **Post-processes the boot script** with `boot_script_processor` to inject:
   - `Config.Provider` support (if runtime config is present)
   - Consolidated protocol paths (if consolidation was performed)
3. **Produces `ElixirReleaseInfo`** provider for the bundle step

### Basic Release

```starlark
load("@rules_mix//:defs.bzl", "elixir_release")

elixir_release(
    name = "my_release",
    app = ":my_app",
    release_version = "1.0.0",
)
```

### Full-Featured Release

```starlark
elixir_release(
    name = "my_release",
    app = ":my_app",
    release_name = "production",
    release_version = "1.0.0",
    env = "prod",

    # Elixir-specific features
    consolidated_protocols = ":consolidated_protocols",
    sys_config = ":sys_config_prod",
    runtime_config_files = ["config/runtime.exs"],

    # Additional OTP apps to include
    extra_apps = [
        "crypto",
        "ssl",
        "inets",
    ],
)
```

**Key Attributes:**

- `app`: Your application target (providing `ErlangAppInfo`)
- `release_name`: Name for the release (defaults to app name)
- `release_version`: Version string
- `env`: Build environment ("prod", "dev", "test", "staging")
- `consolidated_protocols`: Protocol consolidation target (optional)
- `sys_config`: System configuration target (optional)
- `runtime_config_files`: Additional runtime config files to include (optional)
- `extra_apps`: Additional OTP applications to include in the release
- `inject_config_provider`: Whether to inject Config.Provider (default: true)

**What it produces:**

- `{release_name}.rel` - Release specification file
- `{release_name}.script` - Human-readable boot script (with Elixir modifications)
- `{release_name}.boot` - Binary boot file (with Elixir modifications)
- `{release_name}.manifest` - EETF-encoded map of app versions
- `ElixirReleaseInfo` provider for bundling

**Understanding extra_apps:**

The `extra_apps` attribute lets you include OTP applications that aren't explicit dependencies but are needed at runtime:

- `crypto` - Cryptographic operations
- `ssl` - TLS/SSL support
- `inets` - HTTP client/server
- `compiler` - Runtime code compilation (if using `Code.eval_string`, etc.)
- `tools` - Debugging and profiling tools

Note: `elixir_release` automatically includes `["elixir", "logger", "kernel", "stdlib"]` for you.

---

## Step 5: Creating the Bundle with elixir_release_bundle

`elixir_release_bundle` packages everything into a complete, deployable OTP release structure.

### What elixir_release_bundle Does

1. Creates the standard OTP directory structure
2. Copies all BEAM files into `lib/{app}-{version}/ebin/`
3. Copies priv directories into `lib/{app}-{version}/priv/`
4. Copies release files into `releases/{version}/`
5. Copies consolidated protocols (if present) into `releases/{version}/consolidated/`
6. Copies configuration files (sys.config, runtime.exs)
7. Generates a startup script in `bin/{release_name}`
8. Optionally includes ERTS (Erlang Runtime System)

### Basic Bundle

```starlark
load("@rules_mix//:defs.bzl", "elixir_release_bundle")

elixir_release_bundle(
    name = "my_bundle",
    release = ":my_release",
)
```

### Production Bundle with ERTS

```starlark
elixir_release_bundle(
    name = "my_production_bundle",
    release = ":my_release",

    # Include ERTS for self-contained deployment
    include_erts = True,

    # Startup configuration
    startup_command = "foreground",
    command_line_args = [
        "+P", "1000000",  # Max processes
        "+Q", "65536",     # Max ports
    ],
)
```

**Key Attributes:**

- `release`: The `elixir_release` target to bundle
- `include_erts`: Include Erlang runtime (default: False)
  - `True`: Bundle is self-contained, no Erlang installation needed
  - `False`: Requires Erlang/OTP on target system
- `erts_path`: Custom ERTS path (optional, uses toolchain if not specified)
- `startup_command`: Default startup mode (default: "start")
  - `"start"` / `"daemon"`: Start as background daemon
  - `"console"`: Start with interactive console
  - `"foreground"`: Start in foreground without console
- `command_line_args`: Additional VM arguments

### Bundle Directory Structure

The generated bundle has this structure:

```
my_bundle/
├── bin/
│   └── {release_name}          # Startup script
├── lib/
│   ├── my_app-1.0.0/
│   │   ├── ebin/
│   │   │   ├── Elixir.MyApp.beam
│   │   │   └── my_app.app
│   │   └── priv/
│   │       └── static/
│   ├── jason-1.4.0/
│   │   └── ebin/
│   └── plug-1.15.0/
│       └── ebin/
├── releases/
│   ├── {release_name}.rel
│   └── 1.0.0/
│       ├── consolidated/        # Consolidated protocols
│       │   ├── Elixir.Enumerable.beam
│       │   └── ...
│       ├── runtime.exs         # Runtime configuration
│       ├── sys.config          # System configuration
│       ├── start.boot          # Boot file
│       └── {release_name}.script
└── erts-{version}/             # If include_erts = True
    └── bin/
        └── erl
```

### Running the Bundle

After building, you can run your release:

```bash
# Build the bundle
bazel build //:my_bundle

# Extract it
cp -r bazel-bin/my_bundle /opt/my_app

# Run it
/opt/my_app/bin/my_release start      # Start as daemon
/opt/my_app/bin/my_release console    # Interactive console
/opt/my_app/bin/my_release foreground # Foreground mode
```

---

## Complete Example

Here's a complete BUILD.bazel file showing all the pieces together:

```starlark
load("@rules_mix//:defs.bzl",
     "mix_library",
     "protocol_consolidation",
     "elixir_sys_config",
     "elixir_release",
     "elixir_release_bundle")

# Step 1: Build the application
mix_library(
    name = "my_app",
    srcs = glob([
        "lib/**/*.ex",
        "lib/**/*.exs",
    ]),
    mix_config = "mix.exs",
    priv = glob(["priv/**/*"]),
    deps = [
        "@hex_jason//:jason",
        "@hex_plug//:plug",
        "@hex_phoenix//:phoenix",
    ],
)

# Step 2: Consolidate protocols
protocol_consolidation(
    name = "consolidated_protocols",
    app = ":my_app",
)

# Step 3: Generate configuration
elixir_sys_config(
    name = "sys_config_prod",
    src = "config/prod.exs",
    runtime_src = "config/runtime.exs",
    env = "prod",
    app = ":my_app",
)

# Step 4: Create the release
elixir_release(
    name = "my_release",
    app = ":my_app",
    release_name = "my_app_prod",
    release_version = "1.0.0",
    env = "prod",

    # Add Elixir features
    consolidated_protocols = ":consolidated_protocols",
    sys_config = ":sys_config_prod",
    runtime_config_files = ["config/runtime.exs"],

    # Include extra OTP apps
    extra_apps = [
        "crypto",
        "ssl",
        "inets",
        "runtime_tools",
    ],
)

# Step 5: Create the deployable bundle
elixir_release_bundle(
    name = "my_production_bundle",
    release = ":my_release",
    include_erts = True,
    startup_command = "foreground",
    command_line_args = [
        "+P", "1000000",
        "+Q", "65536",
    ],
)
```

Build the bundle:

```bash
bazel build //:my_production_bundle
```

---

## Minimal Example (No Protocols or Config)

If you want a minimal release without protocol consolidation or sys.config:

```starlark
load("@rules_mix//:defs.bzl",
     "mix_library",
     "elixir_release",
     "elixir_release_bundle")

mix_library(
    name = "simple_app",
    srcs = glob(["lib/**/*.ex"]),
    mix_config = "mix.exs",
)

elixir_release(
    name = "simple_release",
    app = ":simple_app",
)

elixir_release_bundle(
    name = "simple_bundle",
    release = ":simple_release",
)
```

---

## Understanding the Providers

Each step produces providers that carry information to the next stage:

### ErlangAppInfo

Produced by: `mix_library`, `elixir_app`

Contains:
- `app_name`: Application name
- `beam`: List of BEAM files and .app file
- `priv`: Private resource files
- `deps`: List of dependencies (also providing ErlangAppInfo)

### ProtocolConsolidationInfo

Produced by: `protocol_consolidation`

Contains:
- `consolidated_dir`: Directory with consolidated protocol BEAM files

### SysConfigInfo

Produced by: `elixir_sys_config`

Contains:
- `sys_config`: The sys.config file
- `has_runtime_config`: Whether runtime config is present
- Metadata about configuration sources

### ErlangReleaseInfo

Produced by: `erlang_release` (internal to `elixir_release`)

Contains:
- Paths to .rel, .script, .boot, manifest files
- Application info
- Release name and version

### ElixirReleaseInfo

Produced by: `elixir_release`

Contains:
- All of `ErlangReleaseInfo`
- Consolidated protocols directory
- Runtime config files
- Environment settings

---

## Troubleshooting

### "Application X not found"

Make sure the application is in your `deps` or `extra_apps`:

```starlark
elixir_release(
    name = "my_release",
    app = ":my_app",
    extra_apps = ["crypto"],  # Add missing OTP app here
)
```

### Protocols not consolidated

Ensure you:
1. Created a `protocol_consolidation` target
2. Passed it to `elixir_release` via `consolidated_protocols`
3. Built the bundle (consolidation happens at bundle time)

### Runtime config not working

Check that:
1. `elixir_sys_config` has `runtime_src` set
2. `elixir_release` has `runtime_config_files` including your runtime.exs
3. `inject_config_provider = True` (this is the default)

### Release won't start

Try:
1. Check that `include_erts = True` or Erlang/OTP is installed on target system
2. Verify all required OTP apps are in `extra_apps`
3. Run with `console` command to see error messages

---

## Next Steps

- Learn about [sys.config generation](./sys_config_generation.md)
- Explore [elixir_release documentation](./elixir_release.md)
- Check out the [examples directory](../examples/) for working projects

---

## Summary

Building a release bundle is a multi-stage process:

1. **`mix_library`/`elixir_app`** - Compile source → bytecode + ErlangAppInfo
2. **`protocol_consolidation`** - Pre-compile protocols → ProtocolConsolidationInfo
3. **`elixir_sys_config`** - Generate config → sys.config + SysConfigInfo
4. **`elixir_release`** - Create OTP release → .rel/.script/.boot files + ElixirReleaseInfo
5. **`elixir_release_bundle`** - Package everything → deployable bundle directory

Each stage builds on the previous one, passing information through Bazel providers, ultimately creating a self-contained release ready for deployment.
