defmodule SysConfigBuilder do
  @moduledoc """
  Builds Erlang sys.config files for Elixir releases with Config.Provider support.

  This tool:
  1. Reads compile-time configs from EETF files (now contains all apps)
  2. Optionally sets up Config.Provider for runtime configuration
  3. Generates proper Erlang term format sys.config
  4. Creates boot script injection instructions if needed
  """

  def main(argv \\ System.argv()) do
    # Ensure Elixir application is started
    {:ok, _} = Application.ensure_all_started(:elixir)

    # Convert charlists to strings if needed (escript may pass charlists)
    string_argv = Enum.map(argv, fn
      arg when is_list(arg) -> List.to_string(arg)
      arg -> arg
    end)

    case parse_args(string_argv) do
      {:ok, opts} ->
        case build_sys_config(opts) do
          :ok -> :ok
          {:error, reason} ->
            IO.puts(:stderr, "Error: #{reason}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, reason)
        IO.puts(:stderr, "")
        IO.puts(:stderr, usage())
        System.halt(1)
    end
  end

  defp build_sys_config(opts) do
    # Read compile-time configs
    compile_config = read_compile_configs(opts[:compile_configs] || [])

    # Add extra static config if provided
    compile_config = merge_extra_config(compile_config, opts[:extra_config] || %{})

    # Build Config.Provider setup if runtime config is enabled
    config_with_provider = if opts[:runtime_config] do
      add_config_provider(compile_config, opts)
    else
      compile_config
    end

    # Write sys.config file
    with :ok <- write_sys_config(opts[:output], config_with_provider, opts[:runtime_config]) do
      # Write boot injection file if needed
      if opts[:boot_injection] do
        write_boot_injection(opts[:boot_injection])
      else
        :ok
      end
    end
  end

  defp read_compile_configs(config_files) do
    config_files
    |> Enum.map(&read_eetf_file/1)
    |> Enum.reduce([], &merge_app_configs/2)
  end

  defp read_eetf_file(path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          term = :erlang.binary_to_term(binary)
          # The new format is a keyword list of all apps
          # It should be a list of {app, config} tuples
          if is_list(term) and Keyword.keyword?(term) do
            term
          else
            # If it's not a keyword list, return empty
            []
          end
        rescue
          _ -> []
        end
      {:error, _} -> []
    end
  end

  defp merge_app_configs(new_config, acc) do
    # Use Keyword.merge with a custom resolver for duplicate keys
    Keyword.merge(acc, new_config, fn _app, existing, new ->
      Config.Reader.merge(existing, new)
    end)
  end

  defp merge_extra_config(config, extra) do
    Enum.reduce(extra, config, fn {app, config_str}, acc ->
      app_atom = String.to_atom(app)
      # Parse the config string as Elixir terms
      {parsed, _} = Code.eval_string(config_str)

      # Use Keyword.update for cleaner code
      Keyword.update(acc, app_atom, parsed, fn existing ->
        Config.Reader.merge(existing, parsed)
      end)
    end)
  end

  defp add_config_provider(config, opts) do
    # Build the Config.Provider initialization structure
    provider_init = build_provider_init(opts)

    # Use Keyword.update with a default value for cleaner code
    Keyword.update(config, :elixir,
      [{:config_provider_init, provider_init}],
      &[{:config_provider_init, provider_init} | &1]
    )
  end

  defp build_provider_init(opts) do
    # Parse runtime path (defaults to Mix convention with releases/{version}/runtime.exs)
    default_path = "{:system, \"RELEASE_ROOT\", \"/releases/0.1.0/runtime.exs\"}"
    runtime_path = parse_runtime_path(opts[:runtime_path] || default_path)

    # Get environment from opts (default to prod)
    env = String.to_atom(opts[:env] || "prod")

    # Build Config.Reader options matching Mix format
    reader_options = [
      {:env, env},
      {:target, :host},
      {:imports, :disabled}
    ]

    # Build providers list with Config.Reader and options
    providers = [{Config.Reader, {runtime_path, reader_options}}]

    # Build config path (where temporary sys.config will be written)
    config_path = {:system, "RELEASE_SYS_CONFIG", ".config"}

    # Create the Config.Provider struct equivalent as a map with __struct__ key
    # This matches Mix's exact format
    %{
      :__struct__ => Config.Provider,
      :providers => providers,
      :config_path => config_path,
      :extra_config => [],
      :reboot_system_after_config => opts[:reboot_after_config] || false,
      :prune_runtime_sys_config_after_boot => opts[:prune_after_boot] || false,
      :validate_compile_env => false
    }
  end

  defp parse_runtime_path(path_str) when is_binary(path_str) do
    # Parse the runtime path string
    # Format: {:system, "ENV_VAR", "/path"} or just "/path"
    if String.starts_with?(path_str, "{:system") do
      # Parse the tuple format
      {parsed, _} = Code.eval_string(path_str)
      case parsed do
        {:system, env_var, path} when is_binary(env_var) and is_binary(path) ->
          {:system, env_var, path}
        _ ->
          path_str
      end
    else
      path_str
    end
  end

  defp write_sys_config(output_path, config, has_runtime) do
    # Build the header
    header = """
    %% coding: utf-8
    %% RUNTIME_CONFIG=#{has_runtime || false}
    """

    # Use Erlang's native formatting for the terms
    formatted_terms = :io_lib.format("~p", [config])

    # File.write accepts iodata directly, no conversion needed
    content = [header, formatted_terms, ".\n"]

    # Write to file
    File.write(output_path, content)
  end

  # All formatting is now handled by Erlang's :io_lib.format/2
  # which properly formats all terms including maps, atoms, binaries, etc.

  defp write_boot_injection(path) do
    # Write boot script injection instructions
    content = """
    %% Boot script injection for Config.Provider.boot()
    %% Add this instruction after elixir application starts:
    {apply, {'Elixir.Config.Provider', boot, []}}
    """
    File.write(path, content)
  end

  defp parse_args(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv,
      strict: [
        output: :string,
        compile_config: [:string, :keep],
        runtime_config: :boolean,
        runtime_file: [:string, :keep],
        runtime_path: :string,
        reboot_after_config: :boolean,
        prune_after_boot: :boolean,
        boot_injection: :string,
        extra_app: [:string, :keep],
        extra_config: [:string, :keep],
        validate: [:string, :keep],
        env: :string,
        help: :boolean
      ],
      aliases: [
        o: :output,
        e: :env,
        h: :help
      ]
    )

    cond do
      opts[:help] ->
        {:error, usage()}

      invalid != [] ->
        {:error, "Invalid arguments: #{inspect(invalid)}"}

      !opts[:output] ->
        {:error, "Missing required argument: --output"}

      true ->
        # Transform opts into a more usable format
        compile_configs = Keyword.get_values(opts, :compile_config)
        runtime_files = Keyword.get_values(opts, :runtime_file)
        extra_apps = Keyword.get_values(opts, :extra_app)
        extra_configs = Keyword.get_values(opts, :extra_config)
        validations = Keyword.get_values(opts, :validate)

        # Pair up extra apps with their configs
        extra = if length(extra_apps) == length(extra_configs) do
          Map.new(Enum.zip(extra_apps, extra_configs))
        else
          %{}
        end

        {:ok, %{
          output: opts[:output],
          compile_configs: compile_configs,
          runtime_config: opts[:runtime_config],
          runtime_files: runtime_files,
          runtime_path: opts[:runtime_path],
          reboot_after_config: opts[:reboot_after_config] || false,
          prune_after_boot: opts[:prune_after_boot] || true,
          boot_injection: opts[:boot_injection],
          extra_config: extra,
          validations: validations,
          env: opts[:env] || "prod"
        }}
    end
  end

  defp usage do
    """
    Usage: sys_config_builder [OPTIONS]

    Builds Erlang sys.config files with Elixir Config.Provider support.

    Required Options:
      --output, -o FILE              Output sys.config file path

    Compile-time Config Options:
      --compile-config FILE          EETF config file (can be repeated)
                                     Each file contains ALL app configurations
      --extra-app APP                Additional app name for static config
      --extra-config CONFIG          Config string for extra app

    Runtime Config Options:
      --runtime-config               Enable runtime configuration
      --runtime-file FILE            Runtime config file to copy (can be repeated)
      --runtime-path PATH            Runtime path template (default: {:system, "RELEASE_ROOT", "/releases/0.1.0/runtime.exs"})
      --reboot-after-config          Restart VM after loading config
      --prune-after-boot            Delete temporary config files after boot
      --boot-injection FILE          Output file for boot script injection

    Other Options:
      --env, -e ENV                  Environment (prod, dev, test) (default: prod)
      --validate RULE                Config validation rule (can be repeated)
      --help, -h                     Show this help

    Examples:
      # Compile-time config only (single file with all apps)
      sys_config_builder -o sys.config --compile-config all_apps.eetf

      # Multiple config files (each contains all apps, will be merged)
      sys_config_builder -o sys.config --compile-config base.eetf --compile-config overrides.eetf

      # With runtime config
      sys_config_builder -o sys.config --compile-config config.eetf --runtime-config \\
        --runtime-file runtime.exs --boot-injection boot.inject
    """
  end
end