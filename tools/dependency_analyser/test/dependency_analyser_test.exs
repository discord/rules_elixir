# Runs the built escript against generated projects. The fixtures use path
# and local git dependencies only, so no test here touches the network.
#
# Not covered: a seeded lock that Hex unlocks and resolves again, because
# that needs a Hex registry. To check it by hand, seed a meta-project from a
# project whose mix.lock pins a version that its mix.exs rejects, then run
# heavy mode: it must exit 1 with "lock entry changed by the fetch".
defmodule DependencyAnalyserTest do
  use ExUnit.Case, async: true

  # See test_helper.exs.
  @moduletag :json

  setup context do
    base = System.get_env("TEST_TMPDIR") || System.tmp_dir!()
    name = context.test |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    tmp = Path.join(base, "#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    {:ok, tmp: tmp}
  end

  describe "light mode" do
    test "seeds the lock, marks roles, and reads dep_details in each project's env", %{tmp: tmp} do
      light_fixture!(tmp)

      assert {0, out, err} = analyse(tmp, "light")

      assert err ==
               "warning: lock conflict outside the dependency graph, ignored: dev_tool " <>
                 "(seed conflict: #{tmp}/app_a: hex 1.0.0; #{tmp}/app_b: hex 1.1.0)\n"

      entries = entries(out)

      assert entries["meta"]["role"] == "project"

      assert entries["meta"]["dep_details"] == [
               %{"name" => "app_a", "env" => "test"},
               %{"name" => "app_b", "env" => "test"}
             ]

      assert entries["app_a"]["role"] == "root"
      assert entries["app_b"]["role"] == "root"
      refute Map.has_key?(entries["lib_c"], "role")
      refute Map.has_key?(entries["fake_hex"], "role")

      # app_a loads with env: :test, so its expressions see :test.
      assert entries["app_a"]["dep_details"] == [
               %{"name" => "lib_c"},
               %{"name" => "lib_d", "only" => ["test"], "env" => "test", "runtime" => false},
               %{"name" => "fake_hex", "only" => ["test"]},
               %{"name" => "dev_tool", "only" => ["dev"], "runtime" => false}
             ]

      # lib_c loads with the default env: :prod. Mix drops its test-only
      # child from the graph, but dep_details still lists the declaration.
      assert entries["lib_c"]["deps"] == []

      assert entries["lib_c"]["dep_details"] == [
               %{"name" => "lib_d", "only" => ["test"], "runtime" => true}
             ]

      assert entries["lib_d"]["dep_details"] == []
      assert entries["lib_c"]["source"] == %{"type" => "path", "path" => "lib_c"}

      # Light mode takes the deps of an external stub from the seeded lock.
      assert entries["fake_hex"]["deps"] == ["transitive"]

      assert Map.keys(read_lock(Path.join(tmp, "meta"))) == [:fake_hex, :transitive]
    end

    test "fails on a conflict in the graph and prints nothing on stdout", %{tmp: tmp} do
      light_fixture!(tmp, fake_hex: "1.1.0")

      assert {1, "", err} = analyse(tmp, "light")

      assert err =~
               "error: lock conflict in the dependency graph: fake_hex " <>
                 "(seed conflict: #{tmp}/app_a: hex 1.0.0; #{tmp}/app_b: hex 1.1.0)\n"

      assert err =~ "warning: lock conflict outside the dependency graph, ignored: dev_tool"
    end

    # Light mode does not fetch fake_hex, so only its lock entry says that
    # it needs transitive.
    test "fails on a conflict that only a lock entry reaches", %{tmp: tmp} do
      light_fixture!(tmp, transitive: "1.1.0")

      assert {1, "", err} = analyse(tmp, "light")

      assert err =~
               "error: lock conflict in the dependency graph: transitive " <>
                 "(seed conflict: #{tmp}/app_a: hex 1.0.0; #{tmp}/app_b: hex 1.1.0)\n"
    end

    test "without a seed, writes no lock and marks only the project", %{tmp: tmp} do
      light_fixture!(tmp)

      assert {0, out, ""} =
               run(tmp, ["--mode", "light", "--dir", Path.join(tmp, "meta"), "--root", tmp])

      entries = entries(out)
      assert entries["meta"]["role"] == "project"

      assert entries
             |> Map.delete("meta")
             |> Enum.all?(fn {_, e} -> not Map.has_key?(e, "role") end)

      assert length(entries["app_a"]["dep_details"]) == 4
      refute File.exists?(Path.join([tmp, "meta", "mix.lock"]))
    end

    test "matches a seed directory through a symlink, and warns about one outside the graph",
         %{tmp: tmp} do
      light_fixture!(tmp)
      link = Path.join(tmp, "link_to_app_a")
      File.ln_s!(Path.join(tmp, "app_a"), link)
      stray = Path.join(tmp, "stray")
      project!(stray, :stray, "[]")
      seed = Enum.join([link, Path.join(tmp, "app_b"), stray], ",")

      assert {0, out, err} =
               run(tmp, ["--dir", Path.join(tmp, "meta"), "--root", tmp, "--seed-lock-from", seed])

      assert err ==
               "warning: --seed-lock-from: #{stray} has no mix.lock entries\n" <>
                 "warning: lock conflict outside the dependency graph, ignored: dev_tool " <>
                 "(seed conflict: #{link}: hex 1.0.0; #{tmp}/app_b: hex 1.1.0)\n" <>
                 "warning: --seed-lock-from: #{stray} is not a path dependency in the graph\n"

      assert entries(out)["app_a"]["role"] == "root"
    end

    # The analyser expands a seed path before it changes into --dir.
    test "reads a relative seed directory from the directory it starts in", %{tmp: tmp} do
      light_fixture!(tmp)
      app_a =
        Path.relative_to(real_path(Path.join(tmp, "app_a")), real_path(start_dir()), force: true)
      seed = "#{app_a},#{Path.join(tmp, "app_b")}"

      assert {0, out, _err} =
               run(tmp, ["--dir", Path.join(tmp, "meta"), "--root", tmp, "--seed-lock-from", seed])

      assert entries(out)["app_a"]["role"] == "root"
    end

    test "rejects a seed directory that is not a Mix project", %{tmp: tmp} do
      light_fixture!(tmp)
      missing = Path.join(tmp, "missing")

      assert {2, "", err} =
               run(tmp, ["--dir", Path.join(tmp, "meta"), "--seed-lock-from", missing])

      assert err =~ "error: --seed-lock-from: #{missing} is not a Mix project"
    end
  end

  describe "heavy mode" do
    @describetag :git

    setup %{tmp: tmp}, do: {:ok, git_fixture!(Path.join(tmp, "git_dep"))}

    test "passes when the fetch keeps the seed, and warns about a conflict outside the graph",
         %{tmp: tmp} = ctx do
      locked = {:git, ctx.repo, ctx.v1, [tag: "v1"]}

      heavy_fixture!(tmp, ctx.repo, "v1", %{git_dep: locked, unused: hex(:unused, "1.0.0")}, %{
        git_dep: locked,
        unused: hex(:unused, "1.1.0")
      })

      assert {0, out, err} = analyse(tmp, "heavy")

      assert err ==
               "warning: lock conflict outside the dependency graph, ignored: unused " <>
                 "(seed conflict: #{tmp}/app_a: hex 1.0.0; #{tmp}/app_b: hex 1.1.0)\n"

      assert entries(out)["git_dep"]["source"]["commit"] == ctx.v1
      assert read_lock(Path.join(tmp, "meta")) == %{git_dep: locked}
    end

    test "fails on an entry that the fetch resolves again", %{tmp: tmp} = ctx do
      stale = {:git, ctx.repo, ctx.v1, [tag: "v1"]}
      heavy_fixture!(tmp, ctx.repo, "v2", %{git_dep: stale}, %{git_dep: stale})

      assert {1, "", err} = analyse(tmp, "heavy")

      assert err =~
               "error: lock entry changed by the fetch: git_dep " <>
                 "git #{ctx.repo} #{ctx.v1} -> git #{ctx.repo} #{ctx.v2}\n"
    end

    test "fails on a conflict that the fetch adds to the lock", %{tmp: tmp} = ctx do
      heavy_fixture!(
        tmp,
        ctx.repo,
        "v1",
        %{git_dep: {:git, ctx.repo, ctx.v1, [tag: "v1"]}},
        %{git_dep: {:git, ctx.repo, ctx.v2, [tag: "v1"]}}
      )

      assert {1, "", err} = analyse(tmp, "heavy")

      assert err =~
               "error: lock entry added by the fetch: git_dep git #{ctx.repo} #{ctx.v1} " <>
                 "(seed conflict: #{tmp}/app_a: git #{ctx.repo} #{ctx.v1}; " <>
                 "#{tmp}/app_b: git #{ctx.repo} #{ctx.v2})\n"
    end
  end

  # A meta-project with two roots that share lib_c. fake_hex is in the graph
  # (test-only in roots that load with env: :test), and its lock entry needs
  # transitive. dev_tool is not, because it is dev-only. app_a locks all
  # three to 1.0.0. app_b locks dev_tool to 1.1.0, and the others to the
  # versions in `app_b`.
  defp light_fixture!(tmp, app_b \\ []) do
    app_b = Keyword.merge([fake_hex: "1.0.0", transitive: "1.0.0"], app_b)
    meta!(tmp)

    project!(Path.join(tmp, "app_a"), :app_a, """
    [
      {:lib_c, path: "../lib_c"},
      {:lib_d, path: "../lib_d", only: :test, env: Mix.env(), runtime: Mix.env() != :test},
      {:fake_hex, "~> 1.0", only: [:test]},
      {:dev_tool, "~> 1.0", only: :dev, runtime: false}
    ]
    """)

    project!(Path.join(tmp, "app_b"), :app_b, """
    [
      {:lib_c, path: "../lib_c"},
      {:fake_hex, "~> 1.0", only: :test}
    ]
    """)

    project!(Path.join(tmp, "lib_c"), :lib_c, """
    [{:lib_d, path: "../lib_d", only: :test, runtime: Mix.env() == :prod}]
    """)

    project!(Path.join(tmp, "lib_d"), :lib_d, "[]")

    fake_hex_deps = [{:transitive, "~> 1.0", [hex: :transitive, repo: "hexpm", optional: false]}]

    write_lock!(Path.join(tmp, "app_a"), %{
      fake_hex: hex(:fake_hex, "1.0.0", fake_hex_deps),
      transitive: hex(:transitive, "1.0.0"),
      dev_tool: hex(:dev_tool, "1.0.0")
    })

    write_lock!(Path.join(tmp, "app_b"), %{
      fake_hex: hex(:fake_hex, app_b[:fake_hex], fake_hex_deps),
      transitive: hex(:transitive, app_b[:transitive]),
      dev_tool: hex(:dev_tool, "1.1.0")
    })
  end

  defp heavy_fixture!(tmp, repo, tag, lock_a, lock_b) do
    meta!(tmp)

    for {app, lock} <- [app_a: lock_a, app_b: lock_b] do
      dir = Path.join(tmp, Atom.to_string(app))
      project!(dir, app, ~s([{:git_dep, git: #{inspect(repo)}, tag: #{inspect(tag)}}]))
      write_lock!(dir, lock)
    end
  end

  defp meta!(tmp) do
    project!(Path.join(tmp, "meta"), :meta, """
    [
      {:app_a, path: #{inspect(Path.join(tmp, "app_a"))}, env: :test},
      {:app_b, path: #{inspect(Path.join(tmp, "app_b"))}, env: :test}
    ]
    """)
  end

  defp git_fixture!(dir) do
    project!(dir, :git_dep, "[]")
    git!(dir, ["init", "--quiet"])
    v1 = commit!(dir, "v1")
    File.write!(Path.join(dir, "README"), "v2\n")
    v2 = commit!(dir, "v2")
    %{repo: dir, v1: v1, v2: v2}
  end

  defp commit!(dir, tag) do
    git!(dir, ["add", "."])
    git!(dir, ["-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-qm", tag])
    git!(dir, ["tag", tag])
    dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args])
    out
  end

  defp project!(dir, app, deps) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{Macro.camelize(Atom.to_string(app))}.MixProject do
      use Mix.Project

      def project, do: [app: #{inspect(app)}, version: "0.1.0", deps: deps()]

      defp deps do
        #{deps}
      end
    end
    """)
  end

  defp hex(name, version, deps \\ []) do
    {:hex, name, version, "inner", [:mix], deps, "hexpm", "outer"}
  end

  # The format of Mix.Dep.Lock.write/2.
  defp write_lock!(dir, lock) do
    lines =
      for {app, value} <- Enum.sort(lock) do
        ~s(  "#{app}": #{inspect(value, limit: :infinity)},\n)
      end

    File.write!(Path.join(dir, "mix.lock"), ["%{\n", lines, "}\n"])
  end

  defp read_lock(dir), do: Mix.Dep.Lock.read(Path.join(dir, "mix.lock"))

  defp analyse(tmp, mode) do
    run(tmp, [
      "--mode",
      mode,
      "--dir",
      Path.join(tmp, "meta"),
      "--root",
      tmp,
      "--seed-lock-from",
      Enum.map_join(["app_a", "app_b"], ",", &Path.join(tmp, &1))
    ])
  end

  # Returns {exit_status, stdout, stderr}.
  defp run(tmp, args) do
    srcdir = System.fetch_env!("TEST_SRCDIR")
    # The repository name differs between this module and a consumer.
    [wrapper] =
      Path.wildcard(Path.join(srcdir, "*/tools/dependency_analyser/dependency_analyser"))

    stderr = Path.join(tmp, "stderr_#{System.unique_integer([:positive])}")
    # Each test gets its own homes, because the tests run concurrently.
    home = Path.join(tmp, "home")

    {out, status} =
      System.cmd("bash", ["-c", ~s(exec "$0" "$@" 2>"$ANALYSER_STDERR"), wrapper | args],
        cd: start_dir(),
        env: [
          {"ANALYSER_STDERR", stderr},
          # Without a UTF-8 locale, Elixir prints a warning on stderr.
          {"ERL_FLAGS", "+fnu"},
          {"MIX_HOME", Path.join(home, "mix")},
          {"HEX_HOME", Path.join(home, "hex")},
          {"HEX_OFFLINE", "1"}
        ]
      )

    {status, out, File.read!(stderr)}
  end

  # The wrapper finds the escript relative to the main repository.
  defp start_dir,
    do: Path.join(System.fetch_env!("TEST_SRCDIR"), System.fetch_env!("TEST_WORKSPACE"))

  # What the analyser compares and expands against: getcwd(3) resolves
  # symlinks.
  defp real_path(dir), do: File.cd!(dir, &File.cwd!/0)

  defp entries(out), do: out |> decode_json!() |> Map.new(&{&1["app_name"], &1})

  # Jason is not on the code path of this test, for the reason at the top of
  # seed_lock_test.exs. apply/3 keeps Elixir before 1.18 from warning that
  # JSON is undefined.
  defp decode_json!(text), do: apply(JSON, :decode!, [text])
end
