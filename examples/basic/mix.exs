defmodule Main.Mixfile do
  use Mix.Project

  @version "2.3.0"
  # @source_url "https://github.com/ericmj/decimal"

  def project() do
    [
      app: :main,
      version: @version,
      elixir: "~> 1.8",
      deps: deps(),
      name: "main",
      source_url: @source_url,
      docs: [source_ref: "v#{@version}", main: "readme", extras: ["README.md"]],
      description: description(),
      package: package()
    ]
  end

  def application() do
    []
  end

  defp deps() do
    [
    ]
  end

  defp description() do
    "Arbitrary precision decimal arithmetic."
  end

  defp package() do
    [
      maintainers: ["Eric Meadows-Jönsson"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
