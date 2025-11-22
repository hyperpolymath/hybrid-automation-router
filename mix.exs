defmodule HAR.MixProject do
  use Mix.Project

  def project do
    [
      app: :har,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {HAR.Application, []}
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:nimble_parsec, "~> 1.3"},

      # IPFS integration
      {:ex_ipfs, "~> 0.1.0"},

      # Network & security
      {:x509, "~> 0.8"},
      {:plug_cowboy, "~> 2.6"},

      # Graph database
      {:libgraph, "~> 0.16"},

      # Distributed systems
      {:libcluster, "~> 3.3"},
      {:horde, "~> 0.8"},

      # Observability
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Development & testing
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 0.6", only: :test},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit],
      flags: [:unmatched_returns, :error_handling, :underspecs]
    ]
  end

  defp description do
    """
    HAR (Hybrid Automation Router) - Infrastructure automation router that parses
    configs from any IaC tool and routes/transforms them to any target format.
    Think BGP for infrastructure automation.
    """
  end

  defp package do
    [
      name: "har",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/yourusername/hybrid-automation-router"
      }
    ]
  end
end
