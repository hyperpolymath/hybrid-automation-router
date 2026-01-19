defmodule HAR.MixProject do
  use Mix.Project

  @version "1.0.0-rc1"
  @source_url "https://github.com/hyperpolymath/hybrid-automation-router"

  def project do
    [
      app: :har,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      description: description(),
      package: package(),
      docs: docs(),
      name: "HAR",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :runtime_tools],
      mod: {HAR.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
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

      # Web UI (Phoenix LiveView)
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1.20", override: true},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:bandit, "~> 1.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

      # Graph database
      {:libgraph, "~> 0.16"},

      # Distributed systems
      {:libcluster, "~> 3.3"},
      {:horde, "~> 0.8"},

      # Observability
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.0"},

      # Development & testing
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.2", only: :test},
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
    configs from any IaC tool (Ansible, Salt, Terraform) and routes/transforms them
    to any target format. Think BGP for infrastructure automation.
    """
  end

  defp package do
    [
      name: "har",
      licenses: ["MPL-2.0"],
      maintainers: ["hyperpolymath"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/har"
      },
      files: ~w(
        lib priv config
        mix.exs README.md LICENSE CHANGELOG.adoc
        .formatter.exs
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "HAR",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/har",
      source_url: @source_url,
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.adoc": [title: "Changelog"],
        "docs/FINAL_ARCHITECTURE.md": [title: "Architecture"],
        "docs/CONTROL_PLANE_ARCHITECTURE.md": [title: "Control Plane"],
        "docs/HAR_SECURITY.md": [title: "Security Model"],
        "docs/IOT_IIOT_ARCHITECTURE.md": [title: "IoT/IIoT Integration"],
        "docs/V2_IOT_ROADMAP.md": [title: "v2 IoT Roadmap"]
      ],
      groups_for_modules: [
        "Semantic Graph": [
          HAR.Semantic.Graph,
          HAR.Semantic.Operation,
          HAR.Semantic.Dependency
        ],
        "Control Plane": [
          HAR.ControlPlane.Router,
          HAR.ControlPlane.RoutingTable,
          HAR.ControlPlane.RoutingPlan,
          HAR.ControlPlane.RoutingDecision,
          HAR.ControlPlane.HealthChecker,
          HAR.ControlPlane.PolicyEngine
        ],
        "Data Plane - Parsers": [
          HAR.DataPlane.Parser,
          HAR.DataPlane.Parsers.Ansible,
          HAR.DataPlane.Parsers.Salt,
          HAR.DataPlane.Parsers.Terraform
        ],
        "Data Plane - Transformers": [
          HAR.DataPlane.Transformer,
          HAR.DataPlane.Transformers.Ansible,
          HAR.DataPlane.Transformers.Salt,
          HAR.DataPlane.Transformers.Terraform
        ],
        "Utilities": [
          HAR.YamlFormatter
        ]
      ],
      nest_modules_by_prefix: [
        HAR.Semantic,
        HAR.ControlPlane,
        HAR.DataPlane.Parsers,
        HAR.DataPlane.Transformers
      ]
    ]
  end
end
