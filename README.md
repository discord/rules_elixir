# rules_elixir

Bazel build rules for Elixir projects, providing seamless integration with the Bazel build system.

Compatible with [rules_erlang](https://github.com/rabbitmq/rules_erlang) for building mixed Erlang/Elixir projects.

## Features

- **Multiple build modes**: Support for both low-level `elixir_app` and high-level `mix_library`/`mix_release` workflows
- **Hex package management**: Fetch and build Hex packages directly from hex.pm via bzlmod extensions
- **Testing support**: Built-in ExUnit test runner with `ex_unit_test` rule
- **Flexible Elixir installation**: Use system Elixir, download from GitHub releases, or build from source
- **Interoperability**: Full compatibility with rules_erlang for mixed codebases
- **Mix integration**: Build Mix projects with dependency resolution

## Installation

### Using Bzlmod (Recommended)

Add `rules_elixir` to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "rules_elixir", version = "1.1.0")
bazel_dep(name = "rules_erlang", version = "3.16.0")

# Configure Elixir installation
elixir_config = use_extension("@rules_elixir//bzlmod:extensions.bzl", "elixir_config")

# Option 1: Use Elixir from GitHub releases (recommended)
elixir_config.internal_elixir_from_github_release(
    version = "1.15.0",
    sha256 = "0f4df7574a5f300b5c66f54906222cd46dac0df7233ded165bc8e80fd9ffeb7a",
)

# Option 2: Use system-installed Elixir
# elixir_config.external_elixir_from_path(
#     name = "system",
#     version = "1.15.0",
#     elixir_home = "/usr/local/elixir",
# )

use_repo(elixir_config, "elixir_config")
register_toolchains("@elixir_config//external:toolchain")
```

## Quick Start

### Building a Simple Elixir Application

Create a `BUILD.bazel` file in your project:

```starlark
load("@rules_elixir//:defs.bzl", "mix_library", "mix_release")

mix_library(
    name = "my_app",
    app_name = "my_app",
    mix_config = ":mix.exs",
    srcs = glob(["lib/**/*.ex"]),
)

mix_release(
    name = "my_app_release",
    application = ":my_app",
)
```

Build and run:

```bash
bazel build //:my_app
bazel build //:my_app_release
```

### Adding Hex Dependencies

In your `MODULE.bazel`, use the `elixir_packages` extension:

```starlark
elixir_packages = use_extension("@rules_elixir//bzlmod:extensions.bzl", "elixir_packages")

elixir_packages.hex_package(
    name = "jason",
    version = "1.4.1",
    sha256 = "fbb01ecdfd565b56261302f7e1fcc27c4fb8f32d56eab74db621fc154604a7a1",
)

use_repo(elixir_packages, "jason")
```

Then reference it in your `BUILD.bazel`:

```starlark
mix_library(
    name = "my_app",
    app_name = "my_app",
    mix_config = ":mix.exs",
    srcs = glob(["lib/**/*.ex"]),
    deps = ["@jason"],
)
```

### Writing Tests

Add ExUnit tests to your `BUILD.bazel`:

```starlark
load("@rules_elixir//:ex_unit_test.bzl", "ex_unit_test")

ex_unit_test(
    name = "my_test",
    srcs = [
        "test/test_helper.exs",
        "test/my_test.exs",
    ],
    deps = [":my_app"],
)
```

Run tests:

```bash
bazel test //:my_test
```

## Rules Reference

### mix_library

Compiles an Elixir Mix project into a library.

```starlark
mix_library(
    name = "my_lib",
    app_name = "my_lib",           # Name of the OTP application
    mix_config = ":mix.exs",       # Label to mix.exs file
    srcs = glob(["lib/**/*.ex"]),  # Source files
    deps = [],                      # List of dependencies (ErlangAppInfo providers)
)
```

**Attributes:**
- `name`: Unique name for this target
- `app_name`: Name of the OTP application
- `mix_config`: Label pointing to the `mix.exs` file (default: `:mix.exs`)
- `srcs`: List of source files (`.ex`, `.erl` files)
- `deps`: List of dependencies providing `ErlangAppInfo`
- `data`: Additional data files needed at build time

### mix_release

Creates a Mix release from a compiled application.

```starlark
mix_release(
    name = "my_release",
    application = ":my_app",  # Label to mix_library target
)
```

### elixir_app

Low-level rule for compiling Elixir sources compatible with rules_erlang.

```starlark
elixir_app(
    name = "erlang_app",
    app_name = "my_app",
    srcs = glob(["lib/**/*.ex"]),
    deps = [],
    elixirc_opts = [],
    priv = glob(["priv/**/*"]),
)
```

**Attributes:**
- `app_name`: Name of the application
- `srcs`: Elixir source files (defaults to `lib/**/*.ex`)
- `deps`: Dependencies providing `ErlangAppInfo`
- `elixirc_opts`: Compiler options passed to `elixirc`
- `extra_apps`: Additional OTP applications to include
- `priv`: Files to include in the `priv` directory
- `license_files`: License files to include

### ex_unit_test

Runs ExUnit tests.

```starlark
ex_unit_test(
    name = "my_test",
    srcs = [
        "test/test_helper.exs",
        "test/my_test.exs",
    ],
    deps = [":my_app"],
    env = {
        "MIX_ENV": "test",
    },
)
```

**Attributes:**
- `srcs`: Test files (`.exs` files)
- `deps`: Dependencies providing `ErlangAppInfo`
- `data`: Additional data files needed for tests
- `env`: Environment variables to set during test execution
- `elixir_opts`: Options passed to the `elixir` command

## Module Extensions

### elixir_config

Configures Elixir installation for the workspace.

#### internal_elixir_from_github_release

Downloads and builds Elixir from GitHub releases (recommended).

```starlark
elixir_config.internal_elixir_from_github_release(
    name = "internal",           # Optional, default: "internal"
    version = "1.15.0",         # Elixir version
    sha256 = "0f4df...",        # SHA256 of the release tarball
)
```

#### external_elixir_from_path

Uses a system-installed Elixir.

```starlark
elixir_config.external_elixir_from_path(
    name = "system",
    version = "1.15.0",
    elixir_home = "/usr/local/elixir",
)
```

#### internal_elixir_from_http_archive

Downloads Elixir from a custom URL.

```starlark
elixir_config.internal_elixir_from_http_archive(
    name = "custom",
    version = "1.15.0",
    url = "https://example.com/elixir-1.15.0.tar.gz",
    strip_prefix = "elixir-1.15.0",
    sha256 = "0f4df...",
)
```

### elixir_packages

Fetches Hex packages from hex.pm.

```starlark
elixir_packages = use_extension("@rules_elixir//bzlmod:extensions.bzl", "elixir_packages")

elixir_packages.hex_package(
    name = "jason",                    # Repository name
    version = "1.4.1",                # Package version
    sha256 = "fbb01ecd...",           # SHA256 hash
    pkg = "jason",                     # Package name on hex.pm (if different from name)
    build_file = "//third_party:jason.BUILD",  # Optional custom BUILD file
)

use_repo(elixir_packages, "jason")
```

**Attributes:**
- `name`: Repository name (used in `deps`)
- `version`: Package version
- `sha256`: Expected SHA256 hash of the package
- `pkg`: Package name on hex.pm (if different from `name`)
- `build_file`: Custom BUILD file (optional)
- `build_file_content`: Inline BUILD file content (optional)
- `patches`: List of patch files to apply
- `patch_args`: Arguments for patch command (default: `["-p0"]`)
- `patch_cmds`: Shell commands to run after patching

## Examples

The repository includes several examples in the `examples/` directory:

- **basic**: Simple Mix project demonstrating `mix_library`, `mix_release`, and Hex dependencies
- **internal-elixir**: Using Elixir built from source
- **plug-sample**: Web application using Plug framework

To run an example:

```bash
cd examples/basic
bazel build //:basic
bazel build //:basic-release
```

## Advanced Usage

### Working with Protocol Consolidation

By default, Mix compilation skips protocol consolidation for faster builds. Consolidated protocols are generated during the release phase.

### Custom Build Files for Hex Packages

Some Hex packages may need custom BUILD files if they have non-standard project structures:

```starlark
elixir_packages.hex_package(
    name = "custom_package",
    version = "1.0.0",
    sha256 = "abc123...",
    build_file_content = """
load("@rules_elixir//:defs.bzl", "mix_library")

mix_library(
    name = "custom_package",
    app_name = "custom_package",
    srcs = glob(["src/**/*.ex"]),  # Non-standard source location
    visibility = ["//visibility:public"],
)
""",
)
```

### Mixed Erlang/Elixir Projects

rules_elixir is fully compatible with rules_erlang. You can depend on Erlang libraries from Elixir code and vice versa:

```starlark
load("@rules_erlang//:erlang_app.bzl", "erlang_app")
load("@rules_elixir//:elixir_app.bzl", "elixir_app")

erlang_app(
    name = "my_erlang_lib",
    srcs = glob(["src/**/*.erl"]),
)

elixir_app(
    name = "my_elixir_app",
    app_name = "my_app",
    srcs = glob(["lib/**/*.ex"]),
    deps = [":my_erlang_lib"],
)
```

## Troubleshooting

### Build Errors

If you encounter build errors:

1. Ensure your Elixir version matches between `elixir_config` and your `mix.exs`
2. Check that all Hex dependencies have correct SHA256 hashes
3. Verify that `mix.exs` is correctly referenced in `mix_library`

### Dependency Resolution

rules_elixir does not automatically resolve Mix dependencies. You must explicitly declare all dependencies in both:
- `MODULE.bazel` (using `elixir_packages.hex_package`)
- `BUILD.bazel` (in the `deps` attribute)

Consider using external tooling to generate dependency declarations from `mix.lock`.

## Contributing

Contributions are welcome! Please see the repository for contribution guidelines.

## Copyright and License

(c) 2020-2024 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.  All rights reserved.

Dual licensed under the Apache License Version 2.0 and
Mozilla Public License Version 2.0.

This means that the user can consider the library to be licensed under
**any of the licenses from the list** above. For example, you may
choose the Apache Public License 2.0 and include this library into a
commercial product.

See [LICENSE](./LICENSE) for details.
