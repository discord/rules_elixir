# ex_unit_test cannot put an app from this repository on the code path when
# rules_elixir is an external repository, so compile the module from source.
Code.require_file("../lib/dependency_analyser/cargo_toml.ex", __DIR__)

ExUnit.start()

defmodule DependencyAnalyser.CargoTomlTest do
  use ExUnit.Case, async: true

  alias DependencyAnalyser.CargoToml

  # The manifest that `mix rustler.new` writes. `[lib]` repeats `name`, and
  # must not override the package name.
  @rustler_template """
  [package]
  name = "example_nif"
  version = "0.1.0"
  authors = []
  edition = "2021"

  [lib]
  name = "other_name"
  path = "src/lib.rs"
  crate-type = ["cdylib"]

  [dependencies]
  rustler = "0.37"
  """

  test "reads the package of the rustler template" do
    assert CargoToml.parse(@rustler_template) ==
             %{name: "example_nif", version: "0.1.0", error: nil}
  end

  test "accepts literal strings, comments, spacing and CRLF" do
    toml =
      "# a comment\r\n[ package ] # trailing\r\nname = 'example_nif' # x\r\n  version='1.2.3-rc.1'\r\n"

    assert CargoToml.parse(toml) == %{name: "example_nif", version: "1.2.3-rc.1", error: nil}
  end

  test "ignores keys inside a multi-line string" do
    toml = ~S'''
    [package]
    name = "example_nif"
    description = """
    version = "9.9.9"
    [lib]
    """
    version = "0.1.0"
    '''

    assert CargoToml.parse(toml) == %{name: "example_nif", version: "0.1.0", error: nil}
  end

  test "reports a version inherited from a workspace" do
    for version <- ["version.workspace = true", "version = { workspace = true }"] do
      assert %{name: "example_nif", version: nil, error: error} =
               CargoToml.parse("[package]\nname = \"example_nif\"\n#{version}\n")

      assert error =~ "inherited from a Cargo workspace"
    end
  end

  test "reports a missing version" do
    assert %{name: "example_nif", version: nil, error: "[package] has no `version`"} =
             CargoToml.parse("[package]\nname = \"example_nif\"\n[lib]\nversion = \"0.1.0\"\n")
  end

  test "reports a manifest with no package" do
    assert %{name: nil, version: nil, error: "no [package] table"} =
             CargoToml.parse("[workspace]\nmembers = [\"a\"]\n")
  end

  test "reports a value it cannot read" do
    for value <- [~S("example\_nif"), ~S(""), "1", ~S("""example_nif""")] do
      assert %{name: nil, error: "cannot read the value of `name` in [package]"} =
               CargoToml.parse("[package]\nname = #{value}\nversion = \"0.1.0\"\n")
    end
  end

  test "reports a duplicate key" do
    assert %{version: nil, error: "`version` is set more than once in [package]"} =
             CargoToml.parse(
               "[package]\nname = \"a\"\nversion = \"0.1.0\"\nversion = \"0.2.0\"\n"
             )
  end

  @tag :tmp_dir
  test "finds the native crates, sorted, relative to the package", %{tmp_dir: dir} do
    write = fn path, contents ->
      path = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    write.("native/b_nif/Cargo.toml", "[package]\nname = \"b_nif\"\nversion = \"0.2.0\"\n")
    write.("native/a_nif/Cargo.toml", @rustler_template)

    write.(
      "native/a_nif/nested/Cargo.toml",
      "[package]\nname = \"nested\"\nversion = \"0.0.1\"\n"
    )

    write.("native/Cargo.toml", "[workspace]\n")

    assert CargoToml.native_crates(dir) == [
             %{path: "native/a_nif", name: "example_nif", version: "0.1.0", error: nil},
             %{path: "native/b_nif", name: "b_nif", version: "0.2.0", error: nil}
           ]
  end

  @tag :tmp_dir
  test "a package without native/ has no crates", %{tmp_dir: dir} do
    assert CargoToml.native_crates(dir) == []
  end
end
