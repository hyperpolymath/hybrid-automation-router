defmodule HAR.Application do
  @moduledoc """
  HAR Application supervisor.

  Starts supervision tree with fault-tolerant architecture:
  - Control Plane Supervisor (routing, policy engine)
  - Data Plane Supervisor (parsers, transformers)
  - IPFS Integration
  - Cluster Manager (distributed routing)
  - Telemetry & Metrics
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting HAR (Hybrid Automation Router) v#{HAR.version()}")

    children = [
      # Telemetry setup
      HAR.Telemetry,

      # PubSub for Phoenix LiveView
      {Phoenix.PubSub, name: HAR.PubSub},

      # IPFS node
      {HAR.IPFS.Node, []},

      # Control Plane (routing decisions)
      {HAR.ControlPlane.Supervisor, []},

      # Data Plane (parsers & transformers)
      {HAR.DataPlane.Supervisor, []},

      # Distributed cluster
      {Cluster.Supervisor, [topologies(), [name: HAR.ClusterSupervisor]]},

      # Security manager
      {HAR.Security.Manager, []},

      # Web interface (Phoenix LiveView)
      HARWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: HAR.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp topologies do
    [
      har_cluster: [
        strategy: Cluster.Strategy.Epmd,
        config: [
          hosts: nodes_from_env()
        ]
      ]
    ]
  end

  defp nodes_from_env do
    System.get_env("HAR_CLUSTER_NODES", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_atom/1)
  end
end
