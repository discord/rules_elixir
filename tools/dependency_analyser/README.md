# Dependency Analyser

A tool that analyzes Mix projects and their dependency graphs to extract comprehensive build metadata for use in Bazel builds.

## What It Is

`dependency_analyser` is an Elixir escript that parses a Mix project and all its dependencies, extracting detailed metadata about the dependency graph and outputting it as JSON. This metadata includes:

- Dependency relationships for each package
- Source file types (Erlang, Elixir, leex/yecc)
- Application configuration from `.app` and `.app.src` files
- Package source information (hex packages, git dependencies, path dependencies)
- Git-specific details (URL, resolved commit, sparse checkout paths)
- Mix project configuration (both JSON-friendly and raw Erlang term formats)

## Why It Exists

The purpose of this tool is to bridge the gap between Mix's dependency management and Bazel's hermetic build system. It enables `rules_mix` to:

1. **Bootstrap without Mix**: Generate Bazel build files without running mix during the build process
2. **Enable hermetic builds**: Provide all necessary metadata upfront so Bazel can manage compilation granularly
3. **Interoperate with rules_erlang**: Support mixed Erlang/Elixir projects by understanding both ecosystems
4. **Support advanced features**: Handle mix-based libraries (like Rustler) while maintaining Bazel's build determinism

By extracting dependency metadata separately from compilation, rules_mix can "have its cake and eat it too" - using Mix-based libraries while also providing pre-built assets for each compilation target.

## How to Build

Build the tool using Bazel from the repository root:

```bash
bazel build //tools/dependency_analyser
```

The built escript will be available at:
```
bazel-bin/tools/dependency_analyser/dependency_analyser
```

## How to Use

### Basic Usage

```bash
# Analyze a Mix project in the current directory
dependency_analyser

# Analyze a specific project directory
dependency_analyser /path/to/project

# Or using the --dir flag
dependency_analyser --dir /path/to/project
```

### Options

- `--dir DIR, -d DIR`: Path to Mix project directory (default: current directory)
- `--env ENV, -e ENV`: Set Mix environment - `dev`, `test`, or `prod` (default: `dev`)

### Examples

```bash
# Analyze a project in production mode
dependency_analyser --dir /path/to/project --env prod

# Short form
dependency_analyser /path/to/project -e test
```

### Requirements

The target directory must contain:
- A `mix.exs` file defining the Mix project
- Optionally, a `mix.lock` file for resolved dependencies

### Output

The tool outputs a JSON array to stdout, with each element containing metadata for one package (the main project plus all dependencies). Progress messages are written to stderr.

The JSON structure includes:
- `name`: Package name
- `app`: Application name (from .app file)
- `deps`: List of direct dependencies
- `applications`: OTP applications required
- `erl_files`, `ex_files`, `hrl_files`, `xrl_files`, `yrl_files`: Source file paths by type
- `app_src_file`: Path to .app.src (for Erlang projects)
- `source_type`: Type of dependency (`"hex"`, `"git"`, or `"path"`)
- `git_url`, `git_commit`, `git_sparse`: Git-specific information (when applicable)
- `hex_name`, `hex_version`, `outer_checksum`, `inner_checksum`: Hex-specific information (when applicable)
- `mix_project_config`: Mix project configuration in JSON-friendly format
- `mix_project_config_raw`: Base64-encoded Erlang term representation

## Integration with rules_mix

This tool is exposed by `rules_mix` for consumption by external software and tooling. External tools can use `dependency_analyser` to:
1. Understand the complete dependency graph of a Mix project
2. Extract metadata needed to generate Bazel build targets
3. Obtain information for fetching and caching dependencies
4. Enable hermetic compilation by pre-analyzing the project structure

The JSON output can be consumed by external build generators, IDE integrations, or other tooling that needs to work with Mix projects in a Bazel context.

## Implementation Notes

- The tool deliberately avoids compiling dependencies, only analyzing metadata
- It handles edge cases like sparse git checkouts for monorepo subpackages
- It's built using `rules_elixir` rather than `rules_mix` to avoid circular dependencies during bootstrapping
- It supports both Elixir and Erlang projects (Mix and rebar3 compatibility)
