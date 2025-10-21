defmodule DependencyAnalyser do
  @moduledoc """
  Analyzes Mix projects to extract complete build metadata for hermetic builds.

  This tool analyses a Mix project and outputs all the information needed
  to build it without Mix using only elixirc and erlc.

  ## Usage

      mix run -e "DependencyAnalyser.main(System.argv())"
      # or as an escript:
      DependencyAnalyser.main(["/path/to/project"])
      DependencyAnalyser.main(["/path/to/project", "--json"])
      DependencyAnalyser.main(["--dir", "/path/to/project", "--env", "prod"])

  # ## Command line options

    * `--dir DIR` or `-d DIR` - Path to the Mix project directory (default: current directory)
    * `--json` or `-j` - Output in JSON format
    * `--env ENV` or `-e ENV` - Set Mix environment (default: dev)

  ## Positional arguments

    * If a path is provided as the first argument (without --dir), it will be used as the project directory
  """

  defmodule Manifest do
    @moduledoc """
    The complete build manifest containing all information needed to build without Mix.
    """
    defstruct [
      # Project info
      :app_name,
      :version,
      :description,
      :language,  # :elixir or :erlang

      # Paths
      :source_paths,      # Where to find source files
      :erlang_paths,      # Erlang source directories
      :include_paths,     # Include directories for headers
      :compile_path,      # Where to output .beam files

      # Compilation
      :modules,           # All modules that will be generated
      :registered,        # Registered process names
      :applications,      # OTP application dependencies
      :optional_applications,
      :included_applications,
      :mod,              # Application callback module
      :env,              # Application environment

      # Compiler options
      :erlc_options,     # Options for erlc
      :elixirc_options,  # Options for elixirc

      # Dependencies
      :deps,             # Dependency specifications
      :dep_paths,        # Resolved dependency paths
      :dep_apps,         # List of dependency app names
      :loaded_deps,      # Full Mix.Dep structs for advanced usage

      # Build order
      :compile_order,    # Order to compile files
      :erlang_compile_first, # Erlang files that must compile first

      # File mappings
      :source_to_beam,   # Map of source file to beam file
      :beam_to_source,   # Reverse mapping

      # Metadata
      :mix_env,          # Mix environment used
      :otp_release,      # OTP version
      :elixir_version    # Elixir version
    ]
  end

  def analyse(opts \\ []) do
    # Ensure we're in a Mix project
    unless File.exists?("mix.exs") do
      current_dir = File.cwd!()
      IO.puts(:stderr, """
      Error: No mix.exs found in #{current_dir}
      Please specify a valid Mix project directory:
        DependencyAnalyser.main(["/path/to/project"])
        DependencyAnalyser.main(["--dir", "/path/to/project"])
      """)
      System.halt(1)
    end

    # Start Mix if not already started
    Mix.start()
    Mix.shell(Mix.Shell.Process)

    # Set Mix environment
    env = Keyword.get(opts, :env, :dev)
    Mix.env(env)

    # Load the project
    Code.compile_file("mix.exs")
    Mix.Project.get!()
    config = Mix.Project.config()

    # Compile the project to ensure everything is up to date
    IO.puts("Compiling project...")
    Mix.Task.run("compile", ["--force"])

    # Build the manifest
    manifest = build_manifest(config, env)

    output_json(manifest)

    manifest
  end

  @doc """
  Analyzes each package in the dependency tree individually.
  """
  def analyse_per_package(opts \\ []) do
    # Ensure we're in a Mix project
    unless File.exists?("mix.exs") do
      current_dir = File.cwd!()
      IO.puts(:stderr, """
      Error: No mix.exs found in #{current_dir}
      Please specify a valid Mix project directory:
        DependencyAnalyser.main(["--per-package", "/path/to/project"])
      """)
      System.halt(1)
    end

    # Start Mix if not already started
    Mix.start()
    Mix.shell(Mix.Shell.Process)

    # Set Mix environment
    env = Keyword.get(opts, :env, :dev)
    Mix.env(env)

    # Load the project
    Code.compile_file("mix.exs")
    Mix.Project.get!()
    config = Mix.Project.config()

    # Compile the project to ensure everything is up to date
    IO.puts(:stderr, "Compiling project...")
    Mix.Task.run("compile", ["--force"])

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

  defp build_package_info_for_main_project(app_name, path, mix_config, env) do
    info = %{
      app_name: app_name,
      path: path,
      type: :path  # The main project is always a path dependency
    }

    # Extract app file info - for main project, its path is the main project dir
    app_file_info = extract_app_file(app_name, path, path, env)
    info = if app_file_info, do: Map.put(info, :app_file, app_file_info), else: info

    # Detect file types
    files_present = detect_file_types(path)
    info = Map.put(info, :files_present, files_present)

    # Add the Mix config for the main project
    info = Map.put(info, :mix_config, sanitize_mix_config(mix_config))

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

    # Detect file types
    files_present = detect_file_types(path)
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
            env: format_options_for_json(Keyword.get(app_spec, :env, []))
          }

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp detect_file_types(path) do
    # Common source directories
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
      Path.wildcard(Path.join(dir, pattern)) != []
    end)
  end

  defp find_files_in_dirs(dirs, pattern, base_path) do
    dirs
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join(dir, pattern))
    end)
    |> Enum.map(fn file_path ->
      # Make the path relative to the base package path
      Path.relative_to(file_path, base_path)
    end)
    |> Enum.uniq()
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

  defp build_manifest(config, env) do
    app_name = config[:app]
    compile_path = Mix.Project.compile_path()

    # Read the generated .app file
    app_file = Path.join(compile_path, "#{app_name}.app")
    {:ok, [{:application, ^app_name, app_spec}]} = :file.consult(app_file)

    # Extract dependency information using Mix's APIs
    deps_info = analyse_dependencies_v2()

    # Analyze source files
    source_info = analyse_sources(config)

    # Detect compilation order
    compile_order = detect_compile_order(config)

    %Manifest{
      # Project info
      app_name: app_name,
      version: config[:version],
      description: config[:description] || to_string(app_name),
      language: config[:language] || :elixir,

      # Paths
      source_paths: config[:elixirc_paths] || ["lib"],
      erlang_paths: config[:erlc_paths] || ["src"],
      include_paths: [config[:erlc_include_path] || "include"],
      compile_path: compile_path,

      # From .app file
      modules: Keyword.get(app_spec, :modules, []),
      registered: Keyword.get(app_spec, :registered, []),
      applications: Keyword.get(app_spec, :applications, []),
      optional_applications: Keyword.get(app_spec, :optional_applications, []),
      included_applications: Keyword.get(app_spec, :included_applications, []),
      mod: Keyword.get(app_spec, :mod),
      env: Keyword.get(app_spec, :env, []),

      # Compiler options
      erlc_options: config[:erlc_options] || [],
      elixirc_options: config[:elixirc_options] || [],

      # Dependencies
      deps: deps_info.deps,
      dep_paths: deps_info.paths,
      dep_apps: deps_info.apps,
      loaded_deps: deps_info.loaded_deps,

      # Build order
      compile_order: compile_order,
      erlang_compile_first: source_info.erlang_first,

      # File mappings
      source_to_beam: source_info.source_to_beam,
      beam_to_source: source_info.beam_to_source,

      # Metadata
      mix_env: env,
      otp_release: :erlang.system_info(:otp_release) |> to_string(),
      elixir_version: System.version()
    }
  end

  # New version using Mix's higher-level APIs
  defp analyse_dependencies_v2() do
    # Load all dependencies using Mix's proper API
    # This handles all dependency formats correctly
    deps = Mix.Dep.load_on_environment([])

    # Get dependency paths using Mix.Project API
    deps_paths = Mix.Project.deps_paths()

    # Build dependency specifications from loaded deps
    dep_specs = build_dep_specs(deps)

    # Extract app names for easy reference
    dep_apps = Enum.map(deps, & &1.app)

    %{
      deps: dep_specs,
      paths: deps_paths,
      apps: dep_apps,
      loaded_deps: deps  # Include full structs for advanced analysis
    }
  end

  defp build_dep_specs(deps) do
    # Extract dependency specifications from Mix.Dep structs with resolved versions
    for %Mix.Dep{app: app, requirement: req, opts: opts, top_level: top_level, status: status, scm: scm, manager: manager} = dep <- deps,
        # Only include top-level dependencies in the spec list
        top_level do
      # Build the dependency specification with resolved version and checksum
      build_single_dep_spec_with_lock(dep)
    end
  end

  defp build_single_dep_spec_with_lock(%Mix.Dep{app: app, requirement: req, opts: opts, scm: scm, manager: manager} = dep) do
    # Get lock information for resolved version and checksum
    lock_info = get_lock_info(dep)

    # Filter out internal Mix options
    clean_opts = Keyword.drop(opts, [:dest, :lock, :build, :deps_path, :manager])

    # Determine the dependency type and build the spec
    cond do
      # Path dependency
      Keyword.has_key?(clean_opts, :path) ->
        %{
          type: :path,
          app: app,
          path: Keyword.get(clean_opts, :path)
        }

      # Git dependency
      Keyword.has_key?(clean_opts, :git) ->
        spec = %{
          type: :git,
          app: app,
          git: Keyword.get(clean_opts, :git)
        }

        # Add git-specific options
        spec = if branch = Keyword.get(clean_opts, :branch), do: Map.put(spec, :branch, branch), else: spec
        spec = if tag = Keyword.get(clean_opts, :tag), do: Map.put(spec, :tag, tag), else: spec
        spec = if ref = Keyword.get(clean_opts, :ref), do: Map.put(spec, :ref, ref), else: spec

        # Add resolved git ref from lock if available
        spec = if lock_info && lock_info[:git_ref] do
          Map.put(spec, :resolved_ref, lock_info[:git_ref])
        else
          spec
        end

        # Add sparse field from lock if available
        if lock_info && lock_info[:sparse] do
          Map.put(spec, :sparse, lock_info[:sparse])
        else
          spec
        end

      # Hex dependency (detected by manager or by having :hex in opts or by having a version requirement)
      manager == :hex or Keyword.has_key?(clean_opts, :hex) or (is_binary(req) and lock_info && lock_info[:version]) ->
        spec = %{
          type: :hex,
          app: app,
          requirement: req || "any"
        }

        # Add hex-specific options
        filtered_opts = Keyword.drop(clean_opts, [:hex, :repo, :env])
        spec = if repo = Keyword.get(clean_opts, :repo), do: Map.put(spec, :repo, repo), else: spec
        spec = if env = Keyword.get(clean_opts, :env), do: Map.put(spec, :env, env), else: spec
        spec = if filtered_opts != [], do: Map.put(spec, :opts, Enum.into(filtered_opts, %{})), else: spec

        # Add resolved version and checksums from lock file
        if lock_info && lock_info[:version] do
          spec
          |> Map.put(:resolved_version, lock_info[:version])
          |> Map.put(:outer_checksum, lock_info[:outer_checksum])
        else
          spec
        end

      # Unknown/other dependency type
      true ->
        %{
          type: :unknown,
          app: app,
          requirement: req,
          opts: Enum.into(clean_opts, %{})
        }
    end
  end

  defp get_lock_info(%Mix.Dep{opts: opts}) do
    # Extract lock information from the opts
    case Keyword.get(opts, :lock) do
      # New hex format (Hex v2): {:hex, :app_name, version, inner_checksum, managers, deps, repo, outer_checksum}
      {:hex, _app_name, version, _inner_checksum, _managers, _deps, _repo, outer_checksum}
        when is_binary(outer_checksum) ->
        %{version: version, outer_checksum: outer_checksum}

      # Old hex format (Hex v1): {:hex, :app_name, version, checksum}
      {:hex, _app_name, version, checksum} when is_binary(checksum) ->
        %{version: version, outer_checksum: nil}

      # Git dependencies with options
      {:git, url, ref, lock_opts} when is_list(lock_opts) ->
        info = %{git_url: url, git_ref: ref}
        # Extract sparse field if present
        if sparse = Keyword.get(lock_opts, :sparse) do
          Map.put(info, :sparse, sparse)
        else
          info
        end

      # Git dependencies without options
      {:git, url, ref, _opts} ->
        %{git_url: url, git_ref: ref}

      _ ->
        nil
    end
  end


  defp analyse_sources(config) do
    compile_path = Mix.Project.compile_path()

    # Get all compiled beam files
    _beam_files = Path.wildcard(Path.join(compile_path, "*.beam"))

    # Build mappings - use Enum.reduce for proper accumulation
    elixir_paths = config[:elixirc_paths] || ["lib"]

    {source_to_beam, beam_to_source} =
      for path <- elixir_paths,
          file <- Path.wildcard(Path.join(path, "**/*.ex")),
          module_name = extract_module_from_source(file),
          module_name != nil,
          reduce: {%{}, %{}} do
        {s2b, b2s} ->
          beam_file = Path.join(compile_path, "#{module_name}.beam")
          {Map.put(s2b, file, beam_file), Map.put(b2s, beam_file, file)}
      end

    # Analyze Erlang sources
    erlang_paths = config[:erlc_paths] || ["src"]
    erlang_files = for path <- erlang_paths,
                       file <- Path.wildcard(Path.join(path, "*.erl")),
                       do: file

    # Detect which Erlang files need serial compilation
    erlang_first = detect_erlang_compile_order(erlang_files)

    {final_s2b, final_b2s} =
      for file <- erlang_files, reduce: {source_to_beam, beam_to_source} do
        {s2b, b2s} ->
          module_name = Path.basename(file, ".erl")
          beam_file = Path.join(compile_path, "#{module_name}.beam")
          {Map.put(s2b, file, beam_file), Map.put(b2s, beam_file, file)}
      end

    %{
      source_to_beam: final_s2b,
      beam_to_source: final_b2s,
      erlang_first: erlang_first
    }
  end

  defp extract_module_from_source(file) do
    # Read file and extract module name
    case File.read(file) do
      {:ok, content} ->
        case Regex.run(~r/defmodule\s+([A-Z][\w.]*)/m, content) do
          [_, module] -> "Elixir.#{module}"
          _ -> nil
        end
      _ -> nil
    end
  end

  defp detect_erlang_compile_order(erlang_files) do
    # Files with parse transforms or behaviors must compile first
    erlang_files
    |> Enum.filter(fn file ->
      content = File.read!(file)
      # Check for parse transforms or behavior definitions
      has_transform = content =~ ~r/-compile\(\{parse_transform/
      is_behaviour = content =~ ~r/-callback\s+/ or content =~ ~r/-behaviour\s*\(/
      has_transform or is_behaviour
    end)
  end

  defp detect_compile_order(config) do
    # Mix compilation order
    compilers = config[:compilers] || Mix.compilers()

    # Map Mix compilers to actual compilation steps
    Enum.map(compilers, fn
      :yecc -> {:yecc, "*.yrl"}
      :leex -> {:leex, "*.xrl"}
      :erlang -> {:erlang, "*.erl"}
      :elixir -> {:elixir, "*.ex"}
      :app -> {:app, "generate"}
      other -> {:other, other}
    end)
  end

  defp format_dependencies(manifest) do
    if length(manifest.loaded_deps) == 0 do
      "(none)"
    else
      manifest.loaded_deps
      |> Enum.map(fn %Mix.Dep{app: app, requirement: req, status: status, manager: manager, top_level: top_level} ->
        path = Map.get(manifest.dep_paths, app, "not found")
        level = if top_level, do: "top-level", else: "transitive"
        status_str = format_dep_status(status)
        manager_str = if manager, do: " [#{manager}]", else: ""
        req_str = if req, do: " (#{req})", else: ""

        "  #{app}#{req_str}: #{path}\n    #{level}, #{status_str}#{manager_str}"
      end)
      |> Enum.join("\n")
    end
  end

  defp format_dep_status({:ok, _}), do: "compiled"
  defp format_dep_status(:compile), do: "needs compilation"
  defp format_dep_status(:noappfile), do: "no .app file"
  defp format_dep_status({:unavailable, _}), do: "unavailable"
  defp format_dep_status(status) when is_atom(status), do: to_string(status)
  defp format_dep_status(status), do: inspect(status)

  defp format_compile_order(order) do
    order
    |> Enum.map(fn
      {type, pattern} -> "  #{type}: #{pattern}"
    end)
    |> Enum.join("\n")
  end

  defp format_list([]), do: "  (none)"
  defp format_list(list) do
    list
    |> Enum.map(fn item -> "  - #{item}" end)
    |> Enum.join("\n")
  end

  defp format_mod_for_json(nil), do: nil
  defp format_mod_for_json({module, args}) do
    %{
      module: module,
      args: args
    }
  end

  defp format_deps_for_json(deps) when is_list(deps) do
    # Deps are already in the right format from build_single_dep_spec_with_lock
    deps
  end

  defp format_compile_order_for_json(order) when is_list(order) do
    Enum.map(order, fn
      {type, pattern} -> %{type: type, pattern: pattern}
      other -> other
    end)
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

  defp build_dependency_graph(manifest) do
    # Initialize the graph with empty dependencies for all known apps
    all_apps = [manifest.app_name | Map.keys(manifest.dep_paths)]

    dep_graph = all_apps
    |> Enum.reduce(%{}, fn app, acc ->
      Map.put(acc, app, [])
    end)

    # For each dependency, read its .app file to get its dependencies
    dep_graph = manifest.dep_paths
    |> Enum.reduce(dep_graph, fn {app, path}, acc ->
      deps = get_app_dependencies(app, path, manifest.dep_paths)
      Map.put(acc, app, deps)
    end)

    # Add the main application's dependencies
    # Filter to only include actual dependencies (not OTP apps)
    main_app_deps = manifest.applications
    |> Enum.filter(fn app ->
      # Keep only apps that are in our dependency paths
      Map.has_key?(manifest.dep_paths, app)
    end)

    # Update the main app in the graph
    Map.put(dep_graph, manifest.app_name, main_app_deps)
  end

  defp get_app_dependencies(app, path, all_dep_paths) do
    # Try to read the .app file for this dependency
    app_file = Path.join([path, "ebin", "#{app}.app"])

    case File.exists?(app_file) do
      true ->
        case :file.consult(app_file) do
          {:ok, [{:application, ^app, app_spec}]} ->
            # Extract the applications list from the app spec
            apps = Keyword.get(app_spec, :applications, [])
            # Filter to only include apps that are in our dependencies
            Enum.filter(apps, fn dep_app ->
              Map.has_key?(all_dep_paths, dep_app)
            end)
          _ ->
            []
        end
      false ->
        # If no .app file, try to get from compiled beam in _build
        alt_path = Path.join([path, "_build", "**", "lib", "#{app}", "ebin", "#{app}.app"])
        case Path.wildcard(alt_path) do
          [found_path | _] ->
            case :file.consult(found_path) do
              {:ok, [{:application, ^app, app_spec}]} ->
                apps = Keyword.get(app_spec, :applications, [])
                Enum.filter(apps, fn dep_app ->
                  Map.has_key?(all_dep_paths, dep_app)
                end)
              _ ->
                []
            end
          [] ->
            []
        end
    end
  end

  defp output_json(manifest) do
    # Blob 1: App specification (.app file information)
    app_spec_blob = %{
      app_name: manifest.app_name,
      version: manifest.version,
      description: manifest.description,
      modules: manifest.modules,
      registered: manifest.registered,
      applications: manifest.applications,
      optional_applications: manifest.optional_applications,
      included_applications: manifest.included_applications,
      mod: format_mod_for_json(manifest.mod),
      env: format_options_for_json(manifest.env)
    }

    # Blob 2: Dependencies information
    dependencies_blob = %{
      app_name: manifest.app_name,
      deps: format_deps_for_json(manifest.deps),
      dep_paths: manifest.dep_paths,
      dep_apps: manifest.dep_apps,
      dep_graph: build_dependency_graph(manifest)
    }

    # Blob 3: Metadata and other configuration
    metadata_blob = %{
      app_name: manifest.app_name,
      language: manifest.language,

      paths: %{
        source: manifest.source_paths,
        erlang: manifest.erlang_paths,
        include: manifest.include_paths,
        compile: manifest.compile_path
      },

      compiler: %{
        erlc_options: format_options_for_json(manifest.erlc_options),
        elixirc_options: format_options_for_json(manifest.elixirc_options),
        compile_order: format_compile_order_for_json(manifest.compile_order),
        erlang_compile_first: manifest.erlang_compile_first
      },

      metadata: %{
        mix_env: manifest.mix_env,
        otp_release: manifest.otp_release,
        elixir_version: manifest.elixir_version
      }
    }

    # Output all three blobs as separate JSON objects
    encoded_app_spec = apply(Jason, :encode!, [app_spec_blob, [pretty: true]])
    encoded_dependencies = apply(Jason, :encode!, [dependencies_blob, [pretty: true]])
    encoded_metadata = apply(Jason, :encode!, [metadata_blob, [pretty: true]])

    IO.puts(encoded_app_spec)
    IO.puts(encoded_dependencies)
    IO.puts(encoded_metadata)
  end

  @doc """
  Main entry point for the dependency analyser.

  Accepts command line arguments and runs the analysis.

  ## Examples

      DependencyAnalyser.main([])
      DependencyAnalyser.main(["/path/to/project"])
      DependencyAnalyser.main(["--json"])
      DependencyAnalyser.main(["--dir", "/path/to/project", "--env", "prod"])
      DependencyAnalyser.main(["/path/to/project", "-j", "-e", "test"])
  """
  def main(args \\ System.argv()) do
    # Convert charlists to strings if needed (escript issue)
    args = Enum.map(args, fn
      arg when is_list(arg) -> List.to_string(arg)
      arg when is_binary(arg) -> arg
    end)

    # Parse command line arguments
    {opts, positional_args, _invalid} = OptionParser.parse(args,
      switches: [json: :boolean, env: :string, dir: :string, per_package: :boolean],
      aliases: [j: :json, e: :env, d: :dir, p: :per_package],
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
          if Keyword.get(opts, :per_package, false) do
            analyse_per_package(opts)
          else
            analyse(opts)
          end
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
