defmodule EvalConfig do
  @moduledoc """
  Evaluates Elixir configuration from config/*.exs files for ALL applications.

  This tool reads Elixir configuration files and outputs them in EETF
  (Erlang External Term Format) for use with Bazel's sys.config generation.

  The tool mimics Mix's Config.Reader behavior, extracting configuration
  for ALL applications mentioned in the config files, not just a single app.

  ## Features
  - Reads config/config.exs and environment-specific configs
  - Properly handles import_config statements with graceful fallback
  - Outputs configuration as EETF binary format
  - Safe for parallel execution (no Mix.start())
  - Generates optional human-readable debug files

  ## Output Format
  The EETF file contains a keyword list of all app configurations:
  [{:app1, [...]}, {:app2, [...]}, ...]

  This matches the format returned by Config.Reader.read!/2
  """

  require Logger

  @doc """
  Entry point for the escript.
  """
  def main(args) do
    # Ensure Elixir application is started (needed for Config.Reader)
    {:ok, _} = Application.ensure_all_started(:elixir)

    # Convert charlists to strings
    string_args = Enum.map(args, fn
      arg when is_list(arg) -> List.to_string(arg)
      arg -> arg
    end)

    case parse_args(string_args) do
      {:ok, opts} ->
        extract_config(opts)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        IO.puts(:stderr, "")
        print_usage()
        System.halt(1)
    end
  end

  @doc """
  Extracts configuration for all applications from config files.

  Reads the base config and environment-specific config, merges them,
  and writes the result as EETF.
  """
  def extract_config(opts) do
    env = opts[:env]
    base_dir = opts[:base_dir]
    output = opts[:output]
    verbose = opts[:verbose]
    no_imports = opts[:no_imports]
    no_debug = opts[:no_debug]

    if verbose do
      IO.puts("Extracting all application configs for environment: #{env}")
      IO.puts("Base directory: #{base_dir}")
      IO.puts("Output file: #{output}")
    end

    # Read and merge configurations
    merged_config = read_config(base_dir, env, no_imports, verbose)

    # Write EETF output
    write_eetf(output, merged_config, verbose)

    # Optionally write debug file
    unless no_debug do
      maybe_write_debug(output, merged_config, env, base_dir, verbose)
    end

    if verbose do
      app_count = length(merged_config)
      IO.puts("Successfully extracted configuration for #{app_count} application(s)")
    end
  end

  # For multi-env mode compatibility (if needed in future)
  def extract_config(opts, _env) do
    extract_config(opts)
  end

  @doc """
  Reads configuration files and merges them according to Mix conventions.

  Returns a keyword list of all application configurations.
  """
  def read_config(base_dir, env, no_imports, verbose) do
    # Change to base directory for proper relative path resolution
    original_cwd = File.cwd!()
    File.cd!(base_dir)

    try do
      # Read base config
      config_path = Path.join("config", "config.exs")
      base_config =
        if File.exists?(config_path) do
          if verbose, do: IO.puts("Reading: #{config_path}")
          read_config_file(config_path, env, no_imports, verbose)
        else
          if verbose, do: IO.puts("No config/config.exs found")
          []
        end

      # Read environment-specific config
      env_path = Path.join("config", "#{env}.exs")
      env_config =
        if File.exists?(env_path) do
          if verbose, do: IO.puts("Reading: #{env_path}")
          read_config_file(env_path, env, no_imports, verbose)
        else
          if verbose, do: IO.puts("No config/#{env}.exs found")
          []
        end

      # Merge configurations (env overrides base)
      merged = Config.Reader.merge(base_config, env_config)

      if verbose do
        apps = Keyword.keys(merged)
        IO.puts("Merged config contains: #{inspect(apps)}")
      end

      merged
    after
      File.cd!(original_cwd)
    end
  end

  defp read_config_file(path, env, no_imports, verbose) do
    opts = [
      env: String.to_atom(env),
      target: :host
    ]

    opts = if no_imports do
      Keyword.put(opts, :imports, :disabled)
    else
      opts
    end

    try do
      Config.Reader.read!(path, opts)
    rescue
      e ->
        if verbose do
          IO.puts("Warning: Failed to read #{path}: #{inspect(e)}")
        end

        # Try without imports as fallback
        if not no_imports do
          if verbose, do: IO.puts("Retrying without imports...")
          try do
            Config.Reader.read!(path, Keyword.put(opts, :imports, :disabled))
          rescue
            _ -> []
          end
        else
          []
        end
    end
  end

  @doc """
  Writes configuration to an EETF file.

  The format is a keyword list of all app configurations,
  exactly as returned by Config.Reader.read!/2
  """
  def write_eetf(path, config, verbose) do
    # Ensure parent directory exists
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    # Convert to binary EETF format
    eetf_data = :erlang.term_to_binary(config)

    # Write to file
    File.write!(path, eetf_data, [:binary])

    if verbose do
      size = byte_size(eetf_data)
      app_count = length(config)
      IO.puts("Written EETF to #{path} (#{size} bytes, #{app_count} apps)")
    end
  end

  @doc """
  Optionally writes a human-readable debug file.
  """
  def maybe_write_debug(output_path, config, env, base_dir, verbose) do
    debug_path = output_path <> ".debug"

    # Build debug content
    timestamp = DateTime.utc_now() |> to_string()
    app_count = length(config)

    app_sections = Enum.map(config, fn {app, app_config} ->
      """
      ## Application: #{app}
      #{inspect(app_config, pretty: true, limit: :infinity)}
      """
    end)

    content = """
    # Extracted configuration for ALL applications in #{env} environment
    # Generated at: #{timestamp}
    # Base directory: #{base_dir}
    # Output file: #{output_path}
    # Number of applications: #{app_count}

    #{Enum.join(app_sections, "\n")}
    """

    File.write!(debug_path, content)

    if verbose do
      IO.puts("Written debug file to #{debug_path}")
    end
  end

  @doc """
  Parses command-line arguments.
  """
  def parse_args(args) do
    {opts, _remaining, invalid} = OptionParser.parse(args,
      strict: [
        env: :string,
        envs: :string,
        base_dir: :string,
        output: :string,
        output_dir: :string,
        verbose: :boolean,
        no_imports: :boolean,
        no_debug: :boolean,
        help: :boolean
      ],
      aliases: [
        e: :env,
        b: :base_dir,
        o: :output,
        v: :verbose,
        h: :help
      ]
    )

    cond do
      opts[:help] ->
        print_usage()
        System.halt(0)

      invalid != [] ->
        {:error, "Invalid arguments: #{inspect(invalid)}"}

      # Multi-env mode
      opts[:envs] && opts[:output_dir] ->
        envs = String.split(opts[:envs], ",")
        output_dir = opts[:output_dir]
        base_opts = Keyword.drop(opts, [:envs, :output_dir])

        # Process each environment
        Enum.each(envs, fn env ->
          output_file = Path.join(output_dir, "config_#{env}.eetf")
          env_opts = Keyword.merge(base_opts, [env: env, output: output_file])
          extract_config(env_opts)
        end)

        System.halt(0)

      # Single env mode
      opts[:env] && opts[:output] ->
        # Set defaults
        final_opts = Keyword.merge([
          base_dir: File.cwd!(),
          verbose: false,
          no_imports: false,
          no_debug: false
        ], opts)

        {:ok, final_opts}

      true ->
        {:error, "Required arguments missing. Use --help for usage."}
    end
  end

  @doc """
  Prints usage information.
  """
  def print_usage do
    IO.puts("""
    eval_config - Evaluate ALL Elixir application configurations to EETF

    Usage:
      eval_config [options]

    Required (one of):
      --env, -e <env>          Environment to extract (e.g., prod, dev, test)
      --envs <env1,env2,...>   Multiple environments (with --output-dir)

    Required:
      --output, -o <file>      Output EETF file path (single env mode)
      --output-dir <dir>       Output directory (multi-env mode)

    Optional:
      --base-dir, -b <dir>     Base directory containing config/ (default: current dir)
      --verbose, -v            Enable verbose output
      --no-imports             Disable import_config statements
      --no-debug               Don't generate .debug file
      --help, -h               Show this help

    Examples:
      # Extract prod configuration for all apps
      eval_config --env prod --output bazel-out/config.eetf

      # Extract from specific directory
      eval_config --env dev --base-dir /project --output dev.eetf

      # Extract multiple environments
      eval_config --envs dev,test,prod --output-dir bazel-out/configs/

    Output Format:
      The EETF file contains a keyword list of all application configurations,
      matching the format returned by Config.Reader.read!/2:
      [{:app1, [...]}, {:app2, [...]}, {:logger, [...]}, ...]
    """)
  end
end