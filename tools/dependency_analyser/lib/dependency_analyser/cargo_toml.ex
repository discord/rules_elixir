defmodule DependencyAnalyser.CargoToml do
  @moduledoc """
  Reads the crate name and version of each `native/*/Cargo.toml` in a
  package, so a build tool can find the native crates of a package, e.g. to
  wire a prebuilt NIF.

  Why not a TOML library? OTP and Elixir ship none, and a dependency of this
  tool becomes a module dependency of rules_elixir, all for two keys. This
  reads only single-line `name` and `version` keys of `[package]`, and fails
  closed: anything it can't read is reported in `error`, never guessed.
  """

  # NOTE: the regexes are inline, not module attributes: OTP 28 no longer
  # allows a regex in a module attribute (Elixir v1.18 CHANGELOG, OTP 28).

  @doc """
  One map per `native/*/Cargo.toml` under `package_dir`, sorted by `path`.

  Each map has `path` (relative to `package_dir`), `name`, `version` and
  `error`. `error` is `nil` when both `name` and `version` were read.
  """
  def native_crates(package_dir) do
    package_dir
    |> Path.join("native/*/Cargo.toml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn manifest ->
      path = manifest |> Path.dirname() |> Path.relative_to(package_dir)

      crate =
        case File.read(manifest) do
          {:ok, contents} ->
            parse(contents)

          {:error, reason} ->
            %{name: nil, version: nil, error: "cannot read: #{:file.format_error(reason)}"}
        end

      Map.put(crate, :path, path)
    end)
  end

  @doc """
  The `name` and `version` of the `[package]` table of a Cargo.toml.

  A version inherited from a Cargo workspace (`version.workspace = true`) is
  an error, not a lookup: the workspace root is usually outside the package.
  """
  def parse(contents) do
    acc =
      contents
      |> String.split(["\r\n", "\n"])
      |> Enum.reduce(%{table: nil, multiline: nil, has_package: false, keys: %{}}, &line/2)

    with {:ok, name} <- fetch(acc, :name),
         {:ok, version} <- fetch(acc, :version) do
      %{name: name, version: version, error: nil}
    else
      {:error, reason} ->
        %{name: ok_or_nil(acc.keys[:name]), version: ok_or_nil(acc.keys[:version]), error: reason}
    end
  end

  # A line inside a multi-line string can look like a header or a key.
  defp line(line, %{multiline: delim} = acc) when is_binary(delim) do
    if String.contains?(line, delim), do: %{acc | multiline: nil}, else: acc
  end

  defp line(line, acc) do
    cond do
      Regex.match?(~r/^\s*#/, line) ->
        acc

      table = header(line) ->
        %{acc | table: table, has_package: acc.has_package or table == "package"}

      acc.table == "package" ->
        %{package_key(acc, line) | multiline: opens_multiline(line)}

      true ->
        %{acc | multiline: opens_multiline(line)}
    end
  end

  defp header(line) do
    case Regex.run(~r/^\s*\[{1,2}([^\[\]]*)\]{1,2}\s*(?:#.*)?$/, line) do
      [_, table] -> String.trim(table)
      nil -> nil
    end
  end

  defp package_key(acc, line) do
    case Regex.run(~r/^\s*(name|version)\s*(\.\s*workspace\s*)?=\s*(.*?)\s*$/, line) do
      [_, key, dotted, value] ->
        key = String.to_existing_atom(key)
        value = read_value(dotted != "", value)
        # TOML forbids a duplicate key, so a second one means a misread.
        value = if Map.has_key?(acc.keys, key), do: :duplicate, else: value
        put_in(acc.keys[key], value)

      nil ->
        acc
    end
  end

  defp read_value(true, value) do
    if Regex.match?(~r/^true\s*(?:#.*)?$/, value), do: :workspace, else: :unreadable
  end

  defp read_value(false, value) do
    cond do
      Regex.match?(~r/^\{\s*workspace\s*=\s*true\s*\}\s*(?:#.*)?$/, value) ->
        :workspace

      match = Regex.run(~r/^"([^"\\]+)"\s*(?:#.*)?$/, value, capture: :all_but_first) ->
        {:ok, hd(match)}

      match = Regex.run(~r/^'([^']+)'\s*(?:#.*)?$/, value, capture: :all_but_first) ->
        {:ok, hd(match)}

      true ->
        :unreadable
    end
  end

  # An odd count of a triple quote leaves a multi-line string open.
  defp opens_multiline(line) do
    Enum.find([~s("""), "'''"], fn delim ->
      line |> String.split(delim) |> length() |> rem(2) == 0
    end)
  end

  defp fetch(%{has_package: false}, _key), do: {:error, "no [package] table"}

  defp fetch(%{keys: keys}, key) do
    case keys[key] do
      {:ok, value} -> {:ok, value}
      nil -> {:error, "[package] has no `#{key}`"}
      :workspace -> {:error, "`#{key}` is inherited from a Cargo workspace"}
      :duplicate -> {:error, "`#{key}` is set more than once in [package]"}
      :unreadable -> {:error, "cannot read the value of `#{key}` in [package]"}
    end
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_), do: nil
end
