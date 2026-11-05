defmodule WaffleAzure.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/phil-a/waffle_azure"

  def project do
    [
      app: :waffle_azure,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: [main: "readme", source_ref: "v#{@version}", extras: ["README.md"]]
    ]
  end

  defp description do
    """
    Provides Microsoft Azure Blob Storage for Waffle.
    """
  end

  defp package do
    [
      maintainers: ["Phil"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(mix.exs README.md LICENSE.md lib)
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:waffle, "~> 2.0"},
      {:req, "~> 0.7"},
      {:plug, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
