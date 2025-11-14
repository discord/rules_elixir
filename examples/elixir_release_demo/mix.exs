defmodule ElixirReleaseDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_release_demo,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ElixirReleaseDemo.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Using Jason as an example dependency
      {:jason, "~> 1.3"}
    ]
  end
end