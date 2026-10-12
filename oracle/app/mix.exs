defmodule LVOracle.MixProject do
  use Mix.Project

  def project do
    [
      app: :lv_oracle,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {LVOracle.Application, []},
      extra_applications: [:logger, :inets]
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, "1.2.12"},
      {:phoenix, "~> 1.8.0"},
      {:bandit, "~> 1.0"},
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
