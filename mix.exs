defmodule Varco.MixProject do
  use Mix.Project

  def project do
    [
      app: :varco,
      version: "0.1.0",
      elixir: ">= 1.17.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl],
      mod: {Varco.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:finch, "~> 0.19"},
      {:mint, "~> 1.6"},
      {:req, "~> 0.5"},
      {:x509, "~> 0.9.0"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      {:libcluster, "~> 3.4"},
      {:castore, "~> 1.0"},
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"}
    ]
  end
end
