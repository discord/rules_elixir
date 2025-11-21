# eval_config

A standalone tool for extracting Elixir application configuration from `config/*.exs` files and encoding it as EETF (Erlang External Term Format) for use in Bazel-built releases.

## Purpose

This tool addresses the challenge of including Mix configuration in Bazel-built Elixir applications. Since Bazel bypasses `mix release`, configuration from `config/*.exs` files would normally be missing from the built artifacts. This tool extracts configuration for specific applications, allowing it to be included in the release.

## Key Features

- **App-specific extraction**: Extracts configuration for a single application, not all apps
- **Multiple environment support**: Can extract configs for dev, test, prod, etc.
- **EETF output format**: Binary format compatible with Erlang/OTP releases
- **Safe for parallel execution**: No `Mix.start()` - each instance runs in isolation
- **Debug output**: Optional human-readable `.debug` files for inspection
- **Import handling**: Graceful fallback when `import_config` fails

## Installation

### Building with Bazel

```bash
bazel build //tools/eval_config:eval_config
```

The built escript will be available at:
```
bazel-bin/tools/eval_config/eval_config
```

## Usage

### Basic Usage

Extract configuration for a single environment:
```bash
eval_config \
  --app my_app \
  --env prod \
  --base-dir /path/to/project \
  --output my_app_prod.eetf
```

### Multiple Environments

Extract configurations for multiple environments at once:
```bash
eval_config \
  --app my_app \
  --envs dev,test,prod \
  --base-dir /path/to/project \
  --output-dir ./configs
```

This creates:
- `configs/my_app_dev.eetf`
- `configs/my_app_test.eetf`
- `configs/my_app_prod.eetf`

### Command-Line Options

| Option | Short | Description |
|--------|-------|-------------|
| `--app` | `-a` | **Required** - Application name to extract config for |
| `--env` | `-e` | Single environment (default: prod) |
| `--envs` | | Multiple environments (comma-separated) |
| `--base-dir` | `-b` | Project directory containing config/ (default: .) |
| `--output` | `-o` | Output file path (for single env) |
| `--output-dir` | | Output directory (for multiple envs) |
| `--verbose` | `-v` | Enable verbose output |
| `--no-imports` | | Disable import_config resolution |
| `--no-debug` | | Skip debug file generation |
| `--help` | `-h` | Show help message |

## Output Format

### EETF File (Binary)

The main output is a binary file containing Erlang External Term Format:
```erlang
{app_name, [key: value, ...]}
```

To inspect the content:
```elixir
binary = File.read!("my_app_prod.eetf")
{app_name, config} = :erlang.binary_to_term(binary)
IO.inspect(config)
```

### Debug File (Optional)

Unless `--no-debug` is specified, a human-readable `.debug` file is also created:
```elixir
# Extracted configuration for :my_app in prod environment
# Generated at: 2025-11-10 12:34:56Z
# Base directory: /path/to/project
# Output file: my_app_prod.eetf
# Number of config keys: 5

[
  database_url: "postgres://localhost/my_app_prod",
  cache_enabled: true,
  port: 8080
]
```

## How It Works

1. **Reads base configuration** from `config/config.exs`
2. **Reads environment-specific config** from `config/<env>.exs`
3. **Merges configurations** using `Config.Reader.merge/2`
4. **Extracts app-specific config** using `Keyword.get(merged, app_name, [])`
5. **Encodes as EETF** using `:erlang.term_to_binary/1`

### Import Handling

The tool handles `import_config` statements gracefully:
- First attempts to read with imports enabled
- If imports fail (e.g., in Bazel sandbox), retries with `imports: :disabled`
- With `--no-imports` flag, always reads without imports

## Integration with Bazel

This tool is designed to be called from Bazel actions in `rules_mix`. The action creator can use the escript instead of generating inline scripts:

```python
def create_elixir_config_action(ctx, app_name, config_files, ...):
    extract_tool = ctx.executable._eval_config_tool

    args = ctx.actions.args()
    args.add("--app", app_name)
    args.add("--env", config_env)
    args.add("--base-dir", base_dir)
    args.add("--output", output_file.path)

    ctx.actions.run(
        executable = extract_tool,
        arguments = [args],
        inputs = config_files,
        outputs = [output_file],
        mnemonic = "ELIXIRCONFIG",
    )
```

## Compatibility

### With combine_configs

The EETF output format is compatible with the existing `combine_configs` tool:
- Both use `:erlang.term_to_binary/1` encoding
- `combine_configs` can merge multiple EETF files at release time

### Differences from combine_configs

| Feature | eval_config | combine_configs |
|---------|-------------------|-----------------|
| Extraction | Single app only | All apps |
| Input | Config directory | Multiple config files |
| Output | `{app, config}` tuple | Full config keyword list |
| Use case | Per-library extraction | Release-time merging |

## Examples

### Testing Config Extraction

Test extraction without building:
```bash
./bazel-bin/tools/eval_config/eval_config \
  --app my_app \
  --env dev \
  --base-dir . \
  --output /tmp/test.eetf \
  --verbose
```

### Debugging Config Issues

Generate debug output to inspect extracted config:
```bash
eval_config \
  --app my_app \
  --env prod \
  --base-dir . \
  --output my_app.eetf

# Inspect the debug file
cat my_app.eetf.debug
```

### Handling Missing Config

The tool handles missing configurations gracefully:
```bash
# App with no config returns empty list
eval_config --app nonexistent_app --output out.eetf
# Creates: {nonexistent_app, []}

# Missing environment falls back to base config
eval_config --app my_app --env staging --output out.eetf
# Uses: config/config.exs only
```

## Safety and Performance

### Parallel Execution

The tool is safe for parallel execution because:
- Each escript runs in its own OS process
- No `Mix.start()` - no global process registration
- No shared state between instances
- Uses `Application.ensure_all_started(:elixir)` for required ETS tables

### Caching

In Bazel, extraction is cached based on:
- Config file contents
- App name and environment
- Tool version

Config changes only trigger re-extraction for affected apps.

## Troubleshooting

### "ETS table does not exist" Error

The tool needs the Elixir application started. This is handled automatically by:
```elixir
{:ok, _} = Application.ensure_all_started(:elixir)
```

### "import_config/1 is not enabled" Warning

This is expected when using `--no-imports` or when config files contain `import_config` statements. The tool will:
1. Show a warning
2. Continue with imports disabled
3. Read environment-specific configs directly

### Empty Configuration

If extraction returns empty config:
- Check the app name matches exactly (atom form)
- Verify config files exist in `config/` directory
- Check config files use correct app name in `config :app_name`

## Development

### Running Tests

```bash
cd tools/eval_config
elixir test/test_extract.exs
```

### Building Locally

```bash
bazel build //tools/eval_config:eval_config
```

## License

Part of the rules_mix project. See main project LICENSE file.
