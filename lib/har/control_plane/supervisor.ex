defmodule HAR.ControlPlane.Supervisor do
  @moduledoc """
  Supervisor for control plane components.

  Manages routing engine, policy engine, health checker, and routing table.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Routing table (loads patterns from YAML)
      {HAR.ControlPlane.RoutingTable, []},
      # Health checker for backend monitoring
      {HAR.ControlPlane.HealthChecker, []},
      # Policy engine for access control
      {HAR.ControlPlane.PolicyEngine, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
