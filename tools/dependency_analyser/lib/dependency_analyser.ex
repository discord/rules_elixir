defmodule DependencyAnalyser do
  @usage """
  Usage: dependency_analyser [--mode light|heavy] [--dir DIR] [--root ROOT]
                             [--seed-lock-from DIR1,DIR2,...]

    --mode, -m        light (default) or heavy.
    --dir, -d         The Mix project to analyse. Default: the current directory.
    --root, -r        Write source.path values relative to this directory.
                      Default: the --dir project.
    --seed-lock-from  Comma-separated project directories. The analyser merges
                      their lock files and OVERWRITES the lockfile of the
                      --dir project with the result before it does anything
                      else. Use this when --dir is a generated project that has
                      these projects as path dependencies, because Mix reads
                      only the lock of the top-level project. If the --dir
                      project declares a seed project as a path dependency,
                      the analyser reads the lockfile that its mix.exs sets.
                      If not, it reads DIR/mix.lock.
    --help, -h        Show this text.

  Modes:

    light  No fetch. In-tree (path) packages get full metadata. External
           packages are stubs, and their deps come from the lock.
    heavy  Fetches all packages and includes full Hex and git metadata.

  Output: a JSON array of package entries on stdout. The --dir project has
  "role": "project". A path entry whose directory is one of the
  --seed-lock-from directories has "role": "root". Path entries and the
  project entry have "dep_details": the only/env/runtime options of each
  declared dependency, evaluated in the Mix env that Mix loads that project
  with.

  Lock seeding:

    A key that the seed projects lock to different values stays out of the
    seed (a "seed conflict").

    heavy  After the fetch, the lock must equal the seed. Any added, changed
           or removed entry is an error. A seed conflict that is not in the
           lock after the fetch is outside the dependency graph, and gets a
           warning.
    light  A seed conflict on an app that the converged graph reaches is an
           error. Light mode does not fetch, so it also follows the deps that
           the lock lists for each package. Any other seed conflict gets a
           warning. Light mode cannot see an entry that Hex resolves again,
           or the deps of a git package that is not on disk. Heavy mode is
           the authority.

    Errors and warnings go to stderr, one line each, prefixed "error: " or
    "warning: ".

  Exit status: 0 on success. 1 if a lock check fails, and then stdout is
  empty. 2 for a usage error. An uncaught error, for example a dependency
  that diverged, exits non-zero from the escript runtime.
  """

  @moduledoc """
  Lightweight dependency analyser for Mix projects.

  #{@usage}
  """

  alias DependencyAnalyser.SeedLock

  def main(args \\ System.argv()) do
    # Escripts pass argv as charlists (Erlang strings), but OptionParser
    # expects binaries. Convert before parsing.
    args = Enum.map(args, fn
      arg when is_list(arg) -> List.to_string(arg)
      arg when is_binary(arg) -> arg
    end)

    case run(args) do
      :ok -> :ok
      {:halt, status} -> System.halt(status)
    end
  end

  # Returns `{:halt, status}` to stop early, after the lines that explain
  # the status are on stderr.
  defp run(args) do
    with {:ok, opts} <- parse_args(args),
         {:ok, mode} <- parse_mode(Keyword.get(opts, :mode, "light")),
         # Expand before the cd, so relative paths mean what the caller meant.
         {:ok, seed_dirs} <- parse_seed_dirs(opts[:seed_lock_from]) do
      File.cd!(Keyword.get(opts, :dir, "."))

      Mix.start()
      Mix.shell(Mix.Shell.Process)
      Mix.env(:test)
      Code.compile_file("mix.exs")
      _project_module = Mix.Project.get!()
      config = Mix.Project.config()

      # root_dir is the monorepo root; all source.path values will be relative to it.
      # Falls back to project dir if --root is not provided.
      root_dir = Keyword.get(opts, :root, File.cwd!())

      seed = seed_lock(seed_dirs, config)

      case mode do
        :light -> run_light(config, root_dir, seed)
        :heavy -> run_heavy(config, root_dir, seed)
      end
    end
  end

  defp parse_args(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          dir: :string,
          mode: :string,
          root: :string,
          seed_lock_from: :string,
          help: :boolean
        ],
        aliases: [d: :dir, m: :mode, r: :root, h: :help]
      )

    cond do
      opts[:help] ->
        IO.write(@usage)
        {:halt, 0}

      rest != [] or invalid != [] ->
        usage_error("unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}")

      true ->
        {:ok, opts}
    end
  end

  defp parse_mode("light"), do: {:ok, :light}
  defp parse_mode("heavy"), do: {:ok, :heavy}
  defp parse_mode(other), do: usage_error("unknown mode: #{other}")

  defp usage_error(message) do
    IO.puts(:stderr, "error: #{message}\n\n#{@usage}")
    {:halt, 2}
  end

  defp parse_seed_dirs(nil), do: {:ok, nil}

  defp parse_seed_dirs(value) do
    dirs = value |> String.split(",", trim: true) |> Enum.map(&Path.expand/1)
    not_mix = Enum.find(dirs, &(not File.regular?(Path.join(&1, "mix.exs"))))

    cond do
      dirs == [] -> usage_error("--seed-lock-from needs at least one directory")
      not_mix -> usage_error("--seed-lock-from: #{not_mix} is not a Mix project (no mix.exs)")
      true -> {:ok, dirs}
    end
  end

  defp seed_lock(nil, _config), do: nil

  defp seed_lock(dirs, config) do
    declared = declared_path_deps(config)

    locks =
      for dir <- dirs do
        file = lockfile(dir, declared[real_path(dir)])
        lock = Mix.Dep.Lock.read(file)

        if lock == %{} do
          IO.puts(:stderr, "warning: --seed-lock-from: #{dir} has no lock entries (#{file})")
        end

        {dir, lock}
      end

    {lock, conflicts} = SeedLock.merge(locks)
    Mix.Dep.Lock.write(lock)

    %{
      dirs: Enum.uniq(dirs),
      roots: MapSet.new(dirs, &real_path/1),
      lock: lock,
      conflicts: conflicts
    }
  end

  # %{real path => {app, env}} for each path dep that the --dir project
  # declares, with the env that Mix loads it with.
  defp declared_path_deps(config) do
    for {app, opts} <- declared_deps(config),
        is_binary(opts[:path]),
        into: %{},
        do: {real_path(opts[:path]), {app, opts[:env] || :prod}}
  end

  # A seed project can keep its lock elsewhere, for example
  # `lockfile: "../../mix.lock"` in an umbrella child, and only its mix.exs
  # says so. Load it under the app name and env that Mix uses for the dep, as
  # in `Mix.Dep.in_dependency/3`. Mix caches a loaded project by app name, so
  # it reuses this one. Under another name, Mix compiles the mix.exs again
  # and warns that it redefines the module.
  #
  # Don't use `in_dependency` itself: it pushes the parent's `:lockfile` down
  # through `Mix.Project.deps_config/1`, so every seed project reports the
  # lockfile of the --dir project. Checked in Mix 1.14.5, 1.15.5 and 1.18.4.
  defp lockfile(dir, nil), do: Path.join(dir, "mix.lock")

  defp lockfile(dir, {app, env}) do
    old_env = Mix.env()

    try do
      Mix.env(env)

      Mix.Project.in_project(app, dir, fn _module ->
        Path.expand(Mix.Project.config()[:lockfile])
      end)
    after
      Mix.env(old_env)
    end
  end

  # The caller and a mix.exs can name one directory in two ways, for example
  # through a symlink. getcwd(3) resolves symlinks, so compare what it returns.
  defp real_path(dir) do
    File.cd!(dir, &File.cwd!/0)
  rescue
    # Mix keeps a path dep whose directory is missing, as unavailable.
    File.Error -> Path.expand(dir)
  end

  defp check_converged(nil, _deps), do: :ok

  defp check_converged(seed, deps) do
    report(SeedLock.check_converged(seed.lock, Enum.map(deps, & &1.app), seed.conflicts))
  end

  defp check_fetched(nil), do: :ok

  defp check_fetched(seed) do
    report(SeedLock.check_fetched(seed.lock, Mix.Dep.Lock.read(), seed.conflicts))
  end

  defp report({errors, warnings}) do
    Enum.each(warnings ++ errors, &IO.puts(:stderr, &1))
    if errors == [], do: :ok, else: {:halt, 1}
  end

  defp warn_unused_seed_dirs(nil, _project_dir, _deps), do: :ok

  defp warn_unused_seed_dirs(seed, project_dir, deps) do
    path_dirs = for dep <- deps, path_dep?(dep), do: dep.opts[:dest]
    used = MapSet.new([project_dir | path_dirs], &real_path/1)

    seed.dirs
    |> Enum.reject(&(real_path(&1) in used))
    |> Enum.each(fn dir ->
      IO.puts(:stderr, "warning: --seed-lock-from: #{dir} is not a path dependency in the graph")
    end)
  end

  # ---------------------------------------------------------------------------
  # Light mode: no fetching, full metadata for path deps, stubs for externals
  # ---------------------------------------------------------------------------

  defp run_light(config, root_dir, seed) do
    deps = converge_deps()
    project_dir = File.cwd!()

    with :ok <- check_converged(seed, deps) do
      warn_unused_seed_dirs(seed, project_dir, deps)

      root_entry = build_root_entry(config, project_dir, root_dir)

      dep_entries =
        Enum.map(deps, fn dep ->
          case classify_dep(dep) do
            :path -> build_path_entry(dep, root_dir, seed)
            type -> build_stub_entry(dep, type)
          end
        end)

      encode_and_output([root_entry | dep_entries])
    end
  end

  # ---------------------------------------------------------------------------
  # Heavy mode: fetch everything, full metadata for all deps
  # ---------------------------------------------------------------------------

  defp run_heavy(config, root_dir, seed) do
    # Fetch deps first
    lock = Mix.Dep.Lock.read()
    _apps = Mix.Dep.Fetcher.all(%{}, lock, [])

    with :ok <- check_fetched(seed) do
      deps = converge_deps()
      project_dir = File.cwd!()
      warn_unused_seed_dirs(seed, project_dir, deps)

      root_entry = build_root_entry(config, project_dir, root_dir)

      dep_entries =
        Enum.map(deps, fn dep ->
          case classify_dep(dep) do
            :path -> build_path_entry(dep, root_dir, seed)
            :hex -> build_hex_entry(dep)
            :git -> build_git_entry(dep)
            :unknown ->
              %Mix.Dep{app: app} = dep
              IO.warn("unknown dep type for #{app}, treating as hex")
              build_hex_entry(dep)
          end
        end)

      encode_and_output([root_entry | dep_entries])
    end
  end

  # ---------------------------------------------------------------------------
  # Entry builders
  # ---------------------------------------------------------------------------

  defp build_root_entry(config, project_dir, root_dir) do
    app_name = Atom.to_string(config[:app])
    declared = declared_deps(config)

    %{
      app_name: app_name,
      deps: Enum.map(declared, fn {app, _opts} -> Atom.to_string(app) end),
      dep_details: dep_details(declared),
      role: "project",
      source: %{type: "path", path: Path.relative_to(project_dir, root_dir)},
      files: scan_files(app_name, project_dir)
    }
  end

  defp build_path_entry(%Mix.Dep{app: app, opts: opts} = dep, root_dir, seed) do
    app_name = Atom.to_string(app)
    dest = Keyword.get(opts, :dest)

    entry = %{
      app_name: app_name,
      deps: extract_dep_names(dep),
      dep_details: path_dep_details(dep),
      source: %{type: "path", path: Path.relative_to(dest, root_dir)},
      files: scan_files(app_name, dest)
    }

    if seed && real_path(dest) in seed.roots, do: Map.put(entry, :role, "root"), else: entry
  end

  defp build_stub_entry(%Mix.Dep{app: app} = dep, type) do
    %{
      app_name: Atom.to_string(app),
      deps: extract_dep_names(dep),
      source: %{type: Atom.to_string(type)},
      files: nil
    }
  end

  defp build_hex_entry(%Mix.Dep{app: app, opts: opts} = dep) do
    app_name = Atom.to_string(app)
    dest = Keyword.get(opts, :dest)
    source = build_hex_source(opts)

    entry = %{
      app_name: app_name,
      deps: extract_dep_names(dep),
      source: source,
      files: scan_files(app_name, dest)
    }

    # Surface hex version as top-level app_version
    if version = source[:version] do
      Map.put(entry, :app_version, version)
    else
      entry
    end
  end

  defp build_git_entry(%Mix.Dep{app: app, opts: opts} = dep) do
    app_name = Atom.to_string(app)
    dest = Keyword.get(opts, :dest)

    %{
      app_name: app_name,
      deps: extract_dep_names(dep),
      source: build_git_source(opts),
      files: scan_files(app_name, dest)
    }
  end

  # ---------------------------------------------------------------------------
  # Source info builders
  # ---------------------------------------------------------------------------

  defp build_hex_source(opts) do
    case Keyword.get(opts, :lock) do
      {:hex, hex_name, version, _inner, _managers, _deps, _repo, outer_checksum}
      when is_binary(outer_checksum) ->
        %{
          type: "hex",
          hex_name: Atom.to_string(hex_name),
          version: version,
          checksum: outer_checksum
        }

      {:hex, hex_name, version, checksum} ->
        %{
          type: "hex",
          hex_name: Atom.to_string(hex_name),
          version: version,
          checksum: checksum
        }

      _ ->
        %{type: "hex"}
    end
  end

  defp build_git_source(opts) do
    git_url = Keyword.get(opts, :git)

    {commit, sparse} =
      case Keyword.get(opts, :lock) do
        {:git, _url, ref, lock_opts} when is_list(lock_opts) ->
          {ref, Keyword.get(lock_opts, :sparse)}

        {:git, _url, ref, _} ->
          {ref, nil}

        _ ->
          {nil, nil}
      end

    base = %{type: "git"}
    base = if git_url, do: Map.put(base, :git_url, git_url), else: base
    base = if commit, do: Map.put(base, :commit, commit), else: base
    if sparse, do: Map.put(base, :sparse, sparse), else: base
  end

  # ---------------------------------------------------------------------------
  # Dependency classification and name extraction
  # ---------------------------------------------------------------------------

  defp path_dep?(%Mix.Dep{opts: opts}), do: Keyword.has_key?(opts, :path)

  defp classify_dep(%Mix.Dep{opts: opts} = dep) do
    lock = Keyword.get(opts, :lock)

    cond do
      path_dep?(dep) -> :path
      match?({:hex, _, _, _}, lock) or match?({:hex, _, _, _, _, _, _, _}, lock) -> :hex
      Keyword.has_key?(opts, :git) -> :git
      # Default to hex for anything with a hex-shaped lock
      true -> :unknown
    end
  end

  defp extract_dep_names(%Mix.Dep{opts: opts, deps: sub_deps}) do
    lock = Keyword.get(opts, :lock)

    case extract_deps_from_lock(lock) do
      [] ->
        # Fallback: use the dep struct's sub-deps
        Enum.map(sub_deps, fn %Mix.Dep{app: a} -> Atom.to_string(a) end)

      names ->
        names
    end
  end

  defp extract_deps_from_lock(
         {:hex, _name, _version, _inner, _managers, deps, _repo, _outer}
       )
       when is_list(deps) do
    Enum.map(deps, fn
      {name, _req, _opts} when is_atom(name) -> Atom.to_string(name)
      {name, _req} when is_atom(name) -> Atom.to_string(name)
      name when is_atom(name) -> Atom.to_string(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_deps_from_lock(_), do: []

  # ---------------------------------------------------------------------------
  # Dep detail extraction (only:, env:, runtime: from mix.exs dep opts)
  # ---------------------------------------------------------------------------

  # `{app, opts}` for each dep in the project's `:deps`, in the shapes that
  # `with_scm_and_app` in `Mix.Dep.Loader` accepts. Every reader of `:deps`
  # goes through here, because a 2-tuple can hold options with no
  # requirement: `{:app, path: "...", only: :test}`.
  defp declared_deps(config) do
    Enum.flat_map(config[:deps] || [], fn
      {app, opts} when is_atom(app) and is_list(opts) -> [{app, opts}]
      {app, _req} when is_atom(app) -> [{app, []}]
      {app, _req, opts} when is_atom(app) and is_list(opts) -> [{app, opts}]
      _ -> []
    end)
  end

  defp dep_details(declared) do
    Enum.map(declared, fn {app, opts} -> extract_dep_detail(app, opts) end)
  end

  # The converged opts of a dep merge what every parent declared, so they
  # are not what this project declared. Evaluate the project's own mix.exs
  # instead, in the env that Mix loaded it with, because options such as
  # `runtime: Mix.env() != :test` only have a value after evaluation.
  defp path_dep_details(%Mix.Dep{opts: opts} = dep) do
    if Mix.Dep.mix?(dep) and File.regular?(Path.join(opts[:dest], "mix.exs")) do
      Mix.Dep.in_dependency(dep, fn _module ->
        dep_details(declared_deps(Mix.Project.config()))
      end)
    else
      []
    end
  end

  defp extract_dep_detail(dep_name, opts) when is_list(opts) do
    detail = %{name: Atom.to_string(dep_name)}

    detail = case Keyword.get(opts, :only) do
      nil -> detail
      envs when is_list(envs) -> Map.put(detail, :only, Enum.map(envs, &Atom.to_string/1))
      env when is_atom(env) -> Map.put(detail, :only, [Atom.to_string(env)])
      _ -> detail
    end

    detail = case Keyword.get(opts, :env) do
      nil -> detail
      env when is_atom(env) -> Map.put(detail, :env, Atom.to_string(env))
      _ -> detail
    end

    case Keyword.get(opts, :runtime) do
      nil -> detail
      val when is_boolean(val) -> Map.put(detail, :runtime, val)
      _ -> detail
    end
  end

  # ---------------------------------------------------------------------------
  # File scanning
  # ---------------------------------------------------------------------------

  defp scan_files(app_name, path) when is_binary(path) do
    scan_dirs = [path, Path.join(path, "src"), Path.join(path, "lib"), Path.join(path, "include")]

    by_ext =
      scan_dirs
      |> Enum.flat_map(fn dir -> Path.wildcard(Path.join([dir, "**", "*"])) end)
      |> Enum.reject(&File.dir?/1)
      |> Enum.reject(&in_excluded_dir?(&1, path))
      |> Enum.uniq()
      |> Enum.group_by(&Path.extname/1)

    xrl_yrl_paths =
      (Map.get(by_ext, ".xrl", []) ++ Map.get(by_ext, ".yrl", []))
      |> Enum.map(&Path.relative_to(&1, path))

    app_src_path = find_app_src(app_name, path)

    # Detect test files
    test_dir = Path.join(path, "test")
    has_test_files = File.dir?(test_dir) and
      Path.wildcard(Path.join([test_dir, "**", "*.exs"])) |> Enum.any?()
    %{
      has_ex: Map.has_key?(by_ext, ".ex"),
      has_erl: Map.has_key?(by_ext, ".erl"),
      has_hrl: Map.has_key?(by_ext, ".hrl"),
      has_xrl_yrl: xrl_yrl_paths != [],
      xrl_yrl_paths: xrl_yrl_paths,
      has_app_src: app_src_path != nil,
      app_src_path: app_src_path,
      has_mix_exs: File.exists?(Path.join(path, "mix.exs")),
      has_test_files: has_test_files,
      native_crates: DependencyAnalyser.CargoToml.native_crates(path)
    }
  end

  defp scan_files(_app_name, nil), do: nil

  defp in_excluded_dir?(file_path, base_path) do
    file_path
    |> Path.relative_to(base_path)
    |> Path.split()
    |> Enum.any?(fn seg -> seg == "deps" || seg == "_build" end)
  end

  defp find_app_src(app_name, path) do
    app_name_str = to_string(app_name)

    candidates = [
      Path.join([path, "src", "#{app_name_str}.app.src"]),
      Path.join([path, "#{app_name_str}.app.src"])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> nil
      found -> Path.relative_to(found, path)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp converge_deps do
    if function_exported?(Mix.Dep, :load_on_environment, 1) do
      Mix.Dep.load_on_environment([])
    else
      Mix.Dep.Converger.converge([])
    end
  end

  defp encode_and_output(packages) do
    IO.puts(Jason.encode!(packages, pretty: true))
  end
end
