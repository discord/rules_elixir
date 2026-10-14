# ex_unit_test cannot put an app from this repository on the code path when
# rules_elixir is an external repository, so compile the module from source.
Code.require_file("../lib/dependency_analyser/seed_lock.ex", __DIR__)

defmodule DependencyAnalyser.SeedLockTest do
  use ExUnit.Case, async: true

  alias DependencyAnalyser.SeedLock

  defp hex(name, version, checksum \\ "inner") do
    {:hex, name, version, checksum, [:mix], [], "hexpm", "outer"}
  end

  describe "merge/1" do
    test "keeps keys that agree or that one root has, and drops conflicts" do
      locks = [
        {"/a",
         %{
           shared: hex(:shared, "1.0.0"),
           only_a: hex(:only_a, "1.0.0"),
           split: hex(:split, "1.0.0")
         }},
        {"/b",
         %{
           shared: hex(:shared, "1.0.0"),
           only_b: hex(:only_b, "2.0.0"),
           split: hex(:split, "1.1.0")
         }}
      ]

      {seed, conflicts} = SeedLock.merge(locks)

      assert seed == %{
               shared: hex(:shared, "1.0.0"),
               only_a: hex(:only_a, "1.0.0"),
               only_b: hex(:only_b, "2.0.0")
             }

      assert conflicts == %{split: [{"/a", hex(:split, "1.0.0")}, {"/b", hex(:split, "1.1.0")}]}
    end

    # Same version is not enough: a different checksum is a different entry.
    test "treats any difference in the value as a conflict" do
      {seed, conflicts} =
        SeedLock.merge([
          {"/a", %{x: hex(:x, "1.0.0", "one")}},
          {"/b", %{x: hex(:x, "1.0.0", "two")}}
        ])

      assert seed == %{}
      assert Map.keys(conflicts) == [:x]
    end
  end

  describe "diff/2" do
    test "lists added, removed and changed entries in key order" do
      before = %{a: hex(:a, "1.0.0"), b: hex(:b, "1.0.0"), c: hex(:c, "1.0.0")}
      after_ = %{a: hex(:a, "1.0.0"), c: hex(:c, "1.1.0"), d: hex(:d, "1.0.0")}

      assert SeedLock.diff(before, after_) == [
               {:removed, :b, hex(:b, "1.0.0")},
               {:changed, :c, hex(:c, "1.0.0"), hex(:c, "1.1.0")},
               {:added, :d, hex(:d, "1.0.0")}
             ]
    end
  end

  describe "check_fetched/3" do
    test "passes when the fetch keeps the seed" do
      seed = %{a: hex(:a, "1.0.0")}
      assert SeedLock.check_fetched(seed, seed, %{}) == {[], []}
    end

    test "warns about a conflict that stays outside the graph" do
      seed = %{a: hex(:a, "1.0.0")}
      conflicts = %{dev_only: [{"/a", hex(:dev_only, "1.0.0")}, {"/b", hex(:dev_only, "1.1.0")}]}

      assert {[], [warning]} = SeedLock.check_fetched(seed, seed, conflicts)

      assert warning ==
               "warning: lock conflict outside the dependency graph, ignored: dev_only " <>
                 "(seed conflict: /a: hex 1.0.0; /b: hex 1.1.0)"
    end

    test "fails on a conflict that the fetch adds to the lock, with each root's value" do
      conflicts = %{split: [{"/a", hex(:split, "1.0.0")}, {"/b", hex(:split, "1.1.0")}]}
      fetched = %{split: hex(:split, "1.1.0")}

      assert {[error, summary], []} = SeedLock.check_fetched(%{}, fetched, conflicts)

      assert error ==
               "error: lock entry added by the fetch: split hex 1.1.0 " <>
                 "(seed conflict: /a: hex 1.0.0; /b: hex 1.1.0)"

      assert summary =~ ~r/^error: 1 lock entry differs from the seed; align/
    end

    test "fails on an entry that the fetch resolves again" do
      seed = %{a: hex(:a, "1.0.0")}

      assert {[error, _summary], []} =
               SeedLock.check_fetched(seed, %{a: hex(:a, "1.2.0")}, %{})

      assert error == "error: lock entry changed by the fetch: a hex 1.0.0 -> hex 1.2.0"
    end

    test "shows full values when the short descriptions are the same" do
      seed = %{a: hex(:a, "1.0.0", "one")}

      assert {[error, _summary], []} =
               SeedLock.check_fetched(seed, %{a: hex(:a, "1.0.0", "two")}, %{})

      assert error =~ ~s("one")
      assert error =~ ~s("two")
    end

    test "fails on an entry that the fetch removes" do
      seed = %{a: hex(:a, "1.0.0")}
      assert {[error, _summary], []} = SeedLock.check_fetched(seed, %{}, %{})
      assert error == "error: lock entry removed by the fetch: a hex 1.0.0"
    end
  end

  describe "check_converged/2" do
    test "fails on a conflict in the graph and warns about the others" do
      conflicts = %{
        in_graph: [{"/a", hex(:in_graph, "1.0.0")}, {"/b", hex(:in_graph, "1.1.0")}],
        outside: [{"/a", hex(:outside, "1.0.0")}, {"/b", hex(:outside, "1.1.0")}]
      }

      assert {[error, _summary], [warning]} =
               SeedLock.check_converged(conflicts, [:in_graph, :other])

      assert error ==
               "error: lock conflict in the dependency graph: in_graph " <>
                 "(seed conflict: /a: hex 1.0.0; /b: hex 1.1.0)"

      assert warning =~
               ~r/^warning: lock conflict outside the dependency graph, ignored: outside /
    end
  end

  describe "describe/1" do
    test "summarises hex and git entries" do
      assert SeedLock.describe(hex(:a, "1.0.0")) == "hex 1.0.0"

      assert SeedLock.describe({:hex, :a, "1.0.0", "x", [:mix], [], "private", "y"}) ==
               "hex 1.0.0 (private)"

      assert SeedLock.describe({:git, "https://example.com/a.git", "abc123", [tag: "v1"]}) ==
               "git https://example.com/a.git abc123"
    end
  end

  describe "read/1" do
    @tag :tmp_dir
    test "reads quoted keys the way Mix writes them, and a missing lock as empty", %{
      tmp_dir: tmp_dir
    } do
      with_lock = Path.join(tmp_dir, "with_lock")
      without_lock = Path.join(tmp_dir, "without_lock")
      File.mkdir_p!(with_lock)
      File.mkdir_p!(without_lock)

      File.write!(Path.join(with_lock, "mix.lock"), """
      %{
        "a": #{inspect(hex(:a, "1.0.0"))},
      }
      """)

      assert SeedLock.read([with_lock, without_lock]) == [
               {with_lock, %{a: hex(:a, "1.0.0")}},
               {without_lock, %{}}
             ]
    end
  end
end
