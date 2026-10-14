defmodule DependencyAnalyser.SeedLock do
  @moduledoc """
  Builds one lock from the `mix.lock` files of several projects, and checks
  the lock that Mix resolves against it.

  Why is this here? Mix reads only the lock of the top-level project. A
  project that pulls in other projects as `path` dependencies resolves their
  Hex and git packages from scratch, and gets the newest matching versions
  rather than the versions those projects lock. Seeding the top-level lock
  with the merged locks fixes that, and the checks below catch the cases
  where the seed is not enough.

  Everything except `read/1` is pure, so it can be tested without Mix
  projects or the network.
  """

  @type root :: String.t()
  @type lock :: %{optional(atom) => tuple}
  @type conflicts :: %{optional(atom) => [{root, tuple}]}
  @type change ::
          {:added, atom, tuple} | {:removed, atom, tuple} | {:changed, atom, tuple, tuple}

  @doc """
  Reads `mix.lock` from each project directory with Mix's own reader.

  A missing file reads as an empty lock, the same as in Mix.
  """
  @spec read([root]) :: [{root, lock}]
  def read(dirs) do
    for dir <- dirs, do: {dir, Mix.Dep.Lock.read(Path.join(dir, "mix.lock"))}
  end

  @doc """
  Merges the locks of several roots.

  A key that every root which has it locks to the same value goes into the
  seed. A key with two or more different values stays out of the seed, and
  its value in each root that has it goes into the conflicts.
  """
  @spec merge([{root, lock}]) :: {lock, conflicts}
  def merge(locks) do
    locks
    |> Enum.flat_map(fn {root, lock} ->
      Enum.map(lock, fn {key, value} -> {key, {root, value}} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce({%{}, %{}}, fn {key, entries}, {seed, conflicts} ->
      case entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
        [value] -> {Map.put(seed, key, value), conflicts}
        _ -> {seed, Map.put(conflicts, key, entries)}
      end
    end)
  end

  @doc """
  Lists the entries that differ between two locks, sorted by key.
  """
  @spec diff(lock, lock) :: [change]
  def diff(before, after_) do
    (Map.keys(before) ++ Map.keys(after_))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      case {Map.fetch(before, key), Map.fetch(after_, key)} do
        {{:ok, same}, {:ok, same}} -> []
        {:error, {:ok, new}} -> [{:added, key, new}]
        {{:ok, old}, :error} -> [{:removed, key, old}]
        {{:ok, old}, {:ok, new}} -> [{:changed, key, old, new}]
      end
    end)
  end

  @doc """
  Checks the lock after a fetch against the seed.

  Every changed entry is an error. Mix adds a lock entry for every package
  in the graph and keeps entries that the graph does not use, so a
  conflicting key that is still absent after the fetch is outside the graph,
  and only gets a warning.

  Returns `{errors, warnings}` as lines for stderr.
  """
  @spec check_fetched(lock, lock, conflicts) :: {[String.t()], [String.t()]}
  def check_fetched(seed, fetched, conflicts) do
    errors =
      Enum.map(diff(seed, fetched), fn
        {:added, key, new} ->
          "error: lock entry added by the fetch: #{key} #{describe(new)}" <>
            conflict_suffix(conflicts, key)

        {:removed, key, old} ->
          "error: lock entry removed by the fetch: #{key} #{describe(old)}"

        {:changed, key, old, new} ->
          {old, new} = describe_pair(old, new)
          "error: lock entry changed by the fetch: #{key} #{old} -> #{new}"
      end)

    {summarise(errors, "lock entry differs from the seed", "lock entries differ from the seed"),
     outside_graph(conflicts, &(not Map.has_key?(fetched, &1)))}
  end

  @doc """
  Checks the conflicts against the apps of a converged graph, without a
  fetch. A conflicting key that is an app in the graph is an error.

  Returns `{errors, warnings}` as lines for stderr.
  """
  @spec check_converged(conflicts, Enumerable.t()) :: {[String.t()], [String.t()]}
  def check_converged(conflicts, apps) do
    apps = MapSet.new(apps)

    errors =
      for {key, _} <- Enum.sort(conflicts), key in apps do
        "error: lock conflict in the dependency graph: #{key}" <> conflict_suffix(conflicts, key)
      end

    {summarise(errors, "lock conflict in the graph", "lock conflicts in the graph"),
     outside_graph(conflicts, &(&1 not in apps))}
  end

  @doc """
  Describes a lock value in a few words, for example `hex 1.4.4`.
  """
  @spec describe(tuple) :: String.t()
  def describe(value) do
    case value do
      {:hex, _name, version, _checksum, _managers, _deps, "hexpm", _outer} ->
        "hex #{version}"

      {:hex, _name, version, _checksum, _managers, _deps, repo, _outer} ->
        "hex #{version} (#{repo})"

      {:git, url, ref, _opts} ->
        "git #{url} #{ref}"

      other ->
        inspect(other, limit: :infinity)
    end
  end

  # Two values with the same short description differ somewhere else, for
  # example in a checksum. Show all of them.
  defp describe_pair(old, new) do
    case {describe(old), describe(new)} do
      {same, same} -> {inspect(old, limit: :infinity), inspect(new, limit: :infinity)}
      pair -> pair
    end
  end

  defp conflict_suffix(conflicts, key) do
    case Map.fetch(conflicts, key) do
      {:ok, entries} ->
        roots =
          Enum.map_join(entries, "; ", fn {root, value} -> "#{root}: #{describe(value)}" end)

        " (seed conflict: #{roots})"

      :error ->
        ""
    end
  end

  defp outside_graph(conflicts, outside?) do
    for {key, _} <- Enum.sort(conflicts), outside?.(key) do
      "warning: lock conflict outside the dependency graph, ignored: #{key}" <>
        conflict_suffix(conflicts, key)
    end
  end

  defp summarise([], _one, _many), do: []

  defp summarise(errors, one, many) do
    what = if length(errors) == 1, do: one, else: many
    errors ++ ["error: #{length(errors)} #{what}; align the mix.lock files of the seed projects"]
  end
end
