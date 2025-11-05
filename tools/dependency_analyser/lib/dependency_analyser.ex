defmodule DependencyAnalyser do
  @moduledoc """
  Analyzes Mix projects and their dependencies to extract build metadata.

  This tool analyses a Mix project and its dependency tree, outputting
  information about each package for hermetic builds.

  ## Usage

      mix run -e "DependencyAnalyser.main(System.argv())"
      # or as an escript:
      DependencyAnalyser.main(["/path/to/project"])
      DependencyAnalyser.main(["--dir", "/path/to/project", "--env", "prod"])

  ## Command line options

    * `--dir DIR` or `-d DIR` - Path to the Mix project directory (default: current directory)
    * `--env ENV` or `-e ENV` - Set Mix environment (default: dev)

  ## Positional arguments

    * If a path is provided as the first argument (without --dir), it will be used as the project directory
  """

  @doc """
  Analyzes each package in the dependency tree individually.
  """
  def analyse(opts \\ []) do
    # Ensure we're in a Mix project
    unless File.exists?("mix.exs") do
      current_dir = File.cwd!()
      IO.puts(:stderr, """
      Error: No mix.exs found in #{current_dir}
      Please specify a valid Mix project directory:
        DependencyAnalyser.main(["/path/to/project"])
      """)
      System.halt(1)
    end

    Mix.start()
    Mix.shell(Mix.Shell.Process)

    env = Keyword.get(opts, :env, :test)
    Mix.env(env)

    # Load the project
    Code.compile_file("mix.exs")
    Mix.Project.get!()
    config = Mix.Project.config()

    fetch_dependencies(env)

    # Note: We skip compilation here because:
    # 1. The dependency analyser only needs to analyze the dependency tree structure
    # 2. Compilation in an escript environment can fail due to missing runtime modules
    # 3. The fetched dependencies provide enough metadata for analysis
    # If compilation is needed for specific use cases, it should be done separately

    # Load all dependencies - these are already resolved from the root project's perspective
    deps = Mix.Dep.load_on_environment([])

    # Build package info for the main project
    main_project_dir = File.cwd!()
    main_project_info = build_package_info_for_main_project(
      config[:app],
      main_project_dir,
      config,
      env
    )

    # Build info for each dependency using only resolved information
    dep_infos = Enum.map(deps, fn dep ->
      build_dependency_package_info(dep, main_project_dir, env)
    end)

    # Combine all package infos
    all_packages = [main_project_info | dep_infos]

    # Output as JSON
    output = Jason.encode!(all_packages, pretty: true)
    IO.puts(output)
  end

  defp fetch_dependencies(env) do
    # Read the lock file
    lock = Mix.Dep.Lock.read()

    # Set up fetch options similar to mix deps.get
    fetch_opts = [env: env]

    # Fetch all dependencies using Mix.Dep.Fetcher API
    # This is the same API that mix deps.get uses internally
    apps = Mix.Dep.Fetcher.all(%{}, lock, fetch_opts)

    if apps == [] do
      IO.puts(:stderr, "All dependencies are up to date")
    else
      IO.puts(:stderr, "Fetched #{length(apps)} dependencies")
    end
  end

  defp encode_term_to_base64(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  defp capture_mix_project_module_data(mix_config) do
    # Get the Mix.Project module
    project_module = Mix.Project.get!()

    # Capture all public functions we care about
    module_data = %{
      project: mix_config
    }

    # Try to capture application/0 if it exists
    module_data = if function_exported?(project_module, :application, 0) do
      Map.put(module_data, :application, project_module.application())
    else
      module_data
    end

    # Try to capture cli/0 if it exists
    module_data = if function_exported?(project_module, :cli, 0) do
      Map.put(module_data, :cli, project_module.cli())
    else
      module_data
    end

    encode_term_to_base64(module_data)
  end

  defp build_package_info_for_main_project(app_name, path, mix_config, env) do
    info = %{
      app_name: app_name,
      path: path,
      type: :path  # The main project is always a path dependency
    }

    # Extract immediate dependencies from mix config
    immediate_deps = if deps = mix_config[:deps] do
      deps
      |> Enum.map(fn
        {dep_name, _version} when is_atom(dep_name) ->
          Atom.to_string(dep_name)
        {dep_name, _version, _opts} when is_atom(dep_name) ->
          Atom.to_string(dep_name)
        # Handle list format like ["dep_name", "~> 1.0"]
        [dep_name, _version] when is_atom(dep_name) ->
          Atom.to_string(dep_name)
        [dep_name, _version, _opts] when is_atom(dep_name) ->
          Atom.to_string(dep_name)
        _ -> nil
      end)
      |> Enum.filter(&(&1 != nil))
    else
      []
    end

    info = if immediate_deps != [] do
      Map.put(info, :immediate_deps, immediate_deps)
    else
      info
    end

    # Extract app file info - for main project, its path is the main project dir
    app_file_info = extract_app_file(app_name, path, path, env)
    info = if app_file_info, do: Map.put(info, :app_file, app_file_info), else: info

    # Find app.src file if it exists
    app_src_path = find_app_src_file(app_name, path)
    info = if app_src_path, do: Map.put(info, :app_src_path, app_src_path), else: info

    # Detect file types (main project never has sparse checkout)
    files_present = detect_file_types(path, nil)
    info = Map.put(info, :files_present, files_present)

    # Explicitly mark that this is a Mix project (the main project always is)
    info = Map.put(info, :is_mix_project, true)

    # Add the Mix config for the main project
    # Keep sanitized version for backward compatibility
    info = Map.put(info, :mix_config, sanitize_mix_config(mix_config))

    # Add the raw Mix config as base64-encoded term
    info = Map.put(info, :mix_config_term, encode_term_to_base64(mix_config))

    # Add complete Mix.Project module data (includes application/0, cli/0, etc.)
    info = Map.put(info, :mix_project_data_term, capture_mix_project_module_data(mix_config))

    info
  end

  defp build_dependency_package_info(%Mix.Dep{app: app, opts: opts, manager: manager} = dep, main_project_dir, env) do
    path = Keyword.get(opts, :dest)

    # Check lock to determine if it's a hex package
    lock = Keyword.get(opts, :lock)

    type = cond do
      # Check if the lock indicates it's a hex package
      match?({:hex, _, _, _}, lock) or match?({:hex, _, _, _, _, _, _, _}, lock) -> :hex
      manager == :hex -> :hex
      Keyword.has_key?(opts, :path) -> :path
      Keyword.has_key?(opts, :git) -> :git
      true -> :unknown
    end

    info = %{
      app_name: app,
      path: path,
      type: type
    }

    # Add relative_path for path dependencies
    info = if type == :path && Keyword.has_key?(opts, :path) do
      Map.put(info, :relative_path, Keyword.get(opts, :path))
    else
      info
    end

    # Extract immediate dependencies from lock data
    immediate_deps = if lock do
      extract_immediate_deps_from_lock(lock)
    else
      # For path dependencies without lock info, try to get from Mix.Dep.deps
      # but convert to string names
      dep.deps
      |> Enum.map(fn %Mix.Dep{app: dep_app} -> Atom.to_string(dep_app) end)
    end

    info = if immediate_deps != [] do
      Map.put(info, :immediate_deps, immediate_deps)
    else
      info
    end

    # Add hex-specific info if applicable (from resolved lock info)
    info = if type == :hex do
      hex_info = extract_hex_info(dep)
      if hex_info, do: Map.put(info, :hex_info, hex_info), else: info
    else
      info
    end

    # Add git-specific info if applicable
    info = if type == :git do
      git_info = extract_git_info(dep)
      if git_info, do: Map.put(info, :git_info, git_info), else: info
    else
      info
    end

    # Extract app file info - pass main project dir to find deps in _build
    app_file_info = extract_app_file(app, path, main_project_dir, env)
    info = if app_file_info, do: Map.put(info, :app_file, app_file_info), else: info

    # Find app.src file if it exists
    app_src_path = find_app_src_file(app, path)
    info = if app_src_path, do: Map.put(info, :app_src_path, app_src_path), else: info

    # Extract sparse path if available from git_info
    sparse_path = if Map.has_key?(info, :git_info) && info[:git_info][:sparse] do
      info[:git_info][:sparse]
    else
      nil
    end

    # Detect file types
    files_present = detect_file_types(path, sparse_path)
    info = Map.put(info, :files_present, files_present)

    # Note if it's a Mix project but DON'T load its mix.exs
    # We only use the resolved information from the root project
    info = if File.exists?(Path.join(path, "mix.exs")) do
      Map.put(info, :is_mix_project, true)
    else
      info
    end

    info
  end

  defp extract_hex_info(%Mix.Dep{opts: opts}) do
    case Keyword.get(opts, :lock) do
      # New hex format with outer checksum
      {:hex, hex_name, version, _inner_checksum, _managers, _deps, _repo, outer_checksum}
        when is_binary(outer_checksum) ->
        %{
          hex_name: hex_name,
          resolved_version: version,
          outer_checksum: outer_checksum
        }

      # Old hex format without outer checksum
      {:hex, hex_name, version, _checksum} ->
        %{
          hex_name: hex_name,
          resolved_version: version,
          outer_checksum: nil
        }

      _ ->
        nil
    end
  end

  defp extract_git_info(%Mix.Dep{opts: opts}) do
    git_url = Keyword.get(opts, :git)

    # Get lock information for resolved commit and sparse field
    lock_info = case Keyword.get(opts, :lock) do
      {:git, _url, ref, lock_opts} when is_list(lock_opts) ->
        info = %{resolved_commit: ref}
        # Extract sparse field if present
        if sparse = Keyword.get(lock_opts, :sparse) do
          Map.put(info, :sparse, sparse)
        else
          info
        end
      {:git, _url, ref, _opts} ->
        %{resolved_commit: ref}
      _ ->
        nil
    end

    # Only return git info if we have at least the URL
    if git_url do
      git_info = %{git_url: git_url}

      # Add resolved commit if available from lock
      git_info = if lock_info && lock_info[:resolved_commit] do
        Map.put(git_info, :resolved_commit, lock_info[:resolved_commit])
      else
        git_info
      end

      # Add sparse field if available from lock
      if lock_info && lock_info[:sparse] do
        Map.put(git_info, :sparse, lock_info[:sparse])
      else
        git_info
      end
    else
      nil
    end
  end

  defp extract_immediate_deps_from_lock(lock) do
    case lock do
      # New hex format with deps in 6th position
      {:hex, _name, _version, _inner_checksum, _managers, deps, _repo, _outer_checksum}
        when is_list(deps) ->
        # Extract dependency names from the deps list
        # Each dep is usually a tuple like {:dep_name, "~> 1.0", [hex: :dep_name, repo: "hexpm", optional: false]}
        Enum.map(deps, fn
          {dep_name, _version_req, _opts} when is_atom(dep_name) ->
            Atom.to_string(dep_name)
          {dep_name, _version_req} when is_atom(dep_name) ->
            Atom.to_string(dep_name)
          dep_name when is_atom(dep_name) ->
            Atom.to_string(dep_name)
          _ -> nil
        end)
        |> Enum.filter(&(&1 != nil))

      # Old hex format without deps
      {:hex, _name, _version, _checksum} ->
        []

      # Git dependencies - check if they have deps info
      {:git, _url, _ref, opts} when is_list(opts) ->
        # Some git dependencies might have deps in opts
        if deps = Keyword.get(opts, :deps) do
          Enum.map(deps, fn
            {dep_name, _} when is_atom(dep_name) -> Atom.to_string(dep_name)
            dep_name when is_atom(dep_name) -> Atom.to_string(dep_name)
            _ -> nil
          end)
          |> Enum.filter(&(&1 != nil))
        else
          []
        end

      _ ->
        []
    end
  end

  defp extract_app_file(app_name, path, main_project_dir \\ nil, env \\ :dev) do
    # Try standard locations for .app file
    app_file_paths = [
      Path.join([path, "ebin", "#{app_name}.app"]),
      Path.join([path, "_build", "**", "lib", "#{app_name}", "ebin", "#{app_name}.app"])
    ]

    # If we have a main project dir and this is a dependency, also check the main project's _build
    app_file_paths = if main_project_dir && path != main_project_dir do
      app_file_paths ++ [
        Path.join([main_project_dir, "_build", to_string(env), "lib", "#{app_name}", "ebin", "#{app_name}.app"])
      ]
    else
      app_file_paths
    end

    app_file = Enum.find(app_file_paths, &File.exists?/1) ||
               List.first(Path.wildcard(Path.join([path, "_build", "**", "lib", "#{app_name}", "ebin", "#{app_name}.app"])))

    if app_file && File.exists?(app_file) do
      case :file.consult(app_file) do
        {:ok, [{:application, ^app_name, app_spec}]} ->
          # Convert to JSON-friendly format
          %{
            vsn: to_string(Keyword.get(app_spec, :vsn, "")),
            description: to_string(Keyword.get(app_spec, :description, "")),
            modules: Keyword.get(app_spec, :modules, []),
            registered: Keyword.get(app_spec, :registered, []),
            applications: Keyword.get(app_spec, :applications, []),
            optional_applications: Keyword.get(app_spec, :optional_applications, []),
            included_applications: Keyword.get(app_spec, :included_applications, []),
            mod: format_mod_for_json(Keyword.get(app_spec, :mod)),
            env: format_options_for_json(Keyword.get(app_spec, :env, [])),
            # Add raw app_spec as base64-encoded term
            app_spec_term: encode_term_to_base64(app_spec)
          }

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp find_app_src_file(app_name, path) do
    # Common locations for .app.src files
    potential_paths = [
      Path.join([path, "src", "#{app_name}.app.src"]),
      Path.join([path, "#{app_name}.app.src"])
    ]

    # Find the first existing path
    app_src_file = Enum.find(potential_paths, &File.exists?/1)

    # If found, return the path relative to the package path
    if app_src_file do
      Path.relative_to(app_src_file, path)
    else
      nil
    end
  end

  defp detect_file_types(path, _sparse_path \\ nil) do
    # Common source directories
    # Note: When sparse checkout is used, the path already points to the sparse directory
    # So we don't need to modify the scan directories based on sparse_path
    src_dirs = [
      path,
      Path.join(path, "src"),
      Path.join(path, "lib"),
      Path.join(path, "include")
    ]

    # Find xrl and yrl files and make them relative to the package path
    xrl_files = find_files_in_dirs(src_dirs, "*.xrl", path)
    yrl_files = find_files_in_dirs(src_dirs, "*.yrl", path)

    # Combine xrl and yrl files into a single list
    xrl_yrl_files = xrl_files ++ yrl_files

    # Check for each file type
    %{
      erl: exists_in_dirs?(src_dirs, "*.erl"),
      hrl: exists_in_dirs?(src_dirs, "*.hrl"),
      ex: exists_in_dirs?(src_dirs, "*.ex"),
      xrl_yrl_files: xrl_yrl_files
    }
  end

  defp exists_in_dirs?(dirs, pattern) do
    Enum.any?(dirs, fn dir ->
      base_path = get_base_path_for_dir(dir)
      Path.wildcard(Path.join([dir, "**", pattern]))
      |> Enum.reject(fn file_path ->
        is_in_excluded_dir_relative?(file_path, base_path)
      end)
      |> Enum.any?()
    end)
  end

  defp find_files_in_dirs(dirs, pattern, base_path) do
    dirs
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join([dir, "**", pattern]))
    end)
    |> Enum.reject(fn file_path ->
      is_in_excluded_dir_relative?(file_path, base_path)
    end)
    |> Enum.map(fn file_path ->
      # Make the path relative to the base package path
      Path.relative_to(file_path, base_path)
    end)
    |> Enum.uniq()
  end

  defp get_base_path_for_dir(dir) do
    # Get the base package path from a directory
    # Remove trailing src/lib/include to get the package root
    cond do
      String.ends_with?(dir, "/src") -> String.trim_trailing(dir, "/src")
      String.ends_with?(dir, "/lib") -> String.trim_trailing(dir, "/lib")
      String.ends_with?(dir, "/include") -> String.trim_trailing(dir, "/include")
      true -> dir
    end
  end

  defp is_in_excluded_dir_relative?(file_path, base_path) do
    # Make the path relative to the base package path
    relative_path = Path.relative_to(file_path, base_path)
    # Split the relative path into segments
    segments = Path.split(relative_path)
    # Check if any segment is "deps" or "_build" in the relative path
    # This excludes only nested deps/_build dirs within the package
    Enum.any?(segments, fn segment ->
      segment == "deps" || segment == "_build"
    end)
  end

  defp sanitize_mix_config(config) when is_list(config) do
    # Convert keyword list to map and sanitize values
    config
    |> Enum.map(fn {k, v} -> {k, sanitize_config_value(v)} end)
    |> Enum.into(%{})
  end
  defp sanitize_mix_config(config), do: config

  defp sanitize_config_value(value) when is_function(value) do
    # Convert functions to a string representation
    inspect(value)
  end
  defp sanitize_config_value(%Regex{} = regex) do
    # Convert regex to a string representation
    %{
      type: "regex",
      source: regex.source,
      opts: regex.opts
    }
  end
  defp sanitize_config_value(value) when is_struct(value) do
    # For other structs, convert to map and sanitize
    value
    |> Map.from_struct()
    |> Map.put(:__struct__, inspect(value.__struct__))
    |> sanitize_config_value()
  end
  defp sanitize_config_value(value) when is_list(value) do
    # Recursively sanitize lists
    if Keyword.keyword?(value) do
      sanitize_mix_config(value)
    else
      Enum.map(value, &sanitize_config_value/1)
    end
  end
  defp sanitize_config_value(value) when is_map(value) do
    # Recursively sanitize maps
    Map.new(value, fn {k, v} -> {k, sanitize_config_value(v)} end)
  end
  defp sanitize_config_value(value) when is_tuple(value) do
    # Convert tuples to lists for JSON compatibility
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_config_value/1)
  end
  defp sanitize_config_value(value), do: value

  defp format_mod_for_json(nil), do: nil
  defp format_mod_for_json({module, args}) do
    %{
      module: module,
      args: args
    }
  end

  defp format_options_for_json(opts) when is_list(opts) do
    # Convert keyword list to a map, handling nested structures
    Enum.map(opts, fn
      {k, v} when is_list(v) ->
        # Check if it's a keyword list
        if Keyword.keyword?(v) do
          {k, format_options_for_json(v)}
        else
          {k, v}
        end
      {k, v} -> {k, v}
      other -> other
    end)
    |> Enum.into(%{})
  end
  defp format_options_for_json(opts), do: opts

  @doc """
  Main entry point for the dependency analyser.

  Accepts command line arguments and runs the analysis.

  ## Examples

      DependencyAnalyser.main([])
      DependencyAnalyser.main(["/path/to/project"])
      DependencyAnalyser.main(["--dir", "/path/to/project", "--env", "prod"])
      DependencyAnalyser.main(["/path/to/project", "-e", "test"])
  """
  def main(args \\ System.argv()) do
    # Convert charlists to strings if needed (escript issue)
    args = Enum.map(args, fn
      arg when is_list(arg) -> List.to_string(arg)
      arg when is_binary(arg) -> arg
    end)

    # Parse command line arguments
    {opts, positional_args, _invalid} = OptionParser.parse(args,
      switches: [env: :string, dir: :string],
      aliases: [e: :env, d: :dir],
      strict: false
    )

    # Determine the project directory
    # Priority: --dir flag > first positional arg > current directory
    project_dir = cond do
      dir = opts[:dir] ->
        dir
      length(positional_args) > 0 ->
        first_arg = hd(positional_args)
        # Convert to string if it's not already
        first_arg_str = if is_binary(first_arg), do: first_arg, else: to_string(first_arg)
        # Check if it starts with a dash (indicating it's a flag that wasn't parsed)
        if String.starts_with?(first_arg_str, "-") do
          "."
        else
          first_arg_str
        end
      true ->
        "."
    end

    # Convert env string to atom if provided
    opts = if env = opts[:env] do
      Keyword.put(opts, :env, String.to_atom(env))
    else
      opts
    end

    # Change to the project directory
    original_dir = File.cwd!()

    case File.cd(project_dir) do
      :ok ->
        # Run the analyser and then restore original directory
        result = try do
          analyse(opts)
        after
          File.cd!(original_dir)
        end
        result

      {:error, reason} ->
        IO.puts(:stderr, "Error: Cannot change to directory '#{project_dir}': #{inspect(reason)}")
        System.halt(1)
    end
  end
end
