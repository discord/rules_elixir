defmodule PlugSample.MixProject do
  use Mix.Project

  def project do
    [
      app: :plug_sample,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: PlugSample.CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:plug_crypto, "~> 2.0"}
    ]
  end
end