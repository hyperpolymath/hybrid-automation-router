defmodule HAR.ControlPlane.Router do
  @moduledoc """
  Routes operations to appropriate backends based on pattern matching.

  The router is the core of HAR's control plane - it decides which backend
  should handle each operation based on operation type, target characteristics,
  and routing policies.
  """

  alias HAR.Semantic.Graph
  alias HAR.ControlPlane.{RoutingTable, RoutingDecision, RoutingPlan, HealthChecker, PolicyEngine}

  require Logger

  @doc """
  Route a semantic graph to target backend(s).

  ## Options

  - `:target` - Target format (required: `:ansible`, `:salt`, `:terraform`, etc.)
  - `:policies` - List of policy names to apply
  - `:allow_fallback` - Allow fallback backends if primary unavailable

  ## Examples

      iex> Router.route(graph, target: :salt)
      {:ok, %RoutingPlan{}}

      iex> Router.route(graph, target: :ansible, policies: [:security])
      {:ok, %RoutingPlan{}}
  """
  @spec route(Graph.t(), keyword()) :: {:ok, RoutingPlan.t()} | {:error, term()}
  def route(%Graph{} = graph, opts \\ []) do
    target = Keyword.fetch!(opts, :target)

    with :ok <- Graph.validate(graph),
         {:ok, decisions} <- route_operations(graph.vertices, target, opts),
         :ok <- validate_consistency(decisions) do
      plan = %RoutingPlan{
        graph: graph,
        decisions: decisions,
        target: target,
        metadata: %{
          routed_at: DateTime.utc_now(),
          policies_applied: Keyword.get(opts, :policies, [])
        }
      }

      Logger.debug("Routed #{length(decisions)} operations to #{target}")
      {:ok, plan}
    end
  end

  defp route_operations(operations, target, opts) do
    decisions =
      Enum.map(operations, fn op ->
        route_single_operation(op, target, opts)
      end)

    # Check for any routing errors
    errors = Enum.filter(decisions, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(decisions, fn {:ok, decision} -> decision end)}
    else
      {:error, {:routing_failed, errors}}
    end
  end

  defp route_single_operation(operation, target, opts) do
    # 1. Pattern match against routing table
    backends = RoutingTable.match(operation, target)

    # 2. Filter by health status
    healthy_backends = filter_healthy(backends)

    # 3. Apply policies
    allowed_backends = apply_policies(healthy_backends, operation, opts)

    # 4. Select best backend
    case select_backend(allowed_backends, opts) do
      {:ok, backend} ->
        decision = %RoutingDecision{
          operation: operation,
          backend: backend,
          alternatives: Enum.slice(allowed_backends, 1..-1//1),
          reason: :pattern_match,
          timestamp: DateTime.utc_now()
        }

        {:ok, decision}

      {:error, :no_backend_available} = error ->
        error
    end
  end

  defp filter_healthy(backends) do
    # Use HealthChecker to filter out unhealthy backends
    HealthChecker.filter_healthy(backends)
  end

  defp apply_policies(backends, operation, opts) do
    # Use PolicyEngine to apply routing policies
    policies = Keyword.get(opts, :policies, [])
    Logger.debug("Applying policies: #{inspect(policies)}")
    PolicyEngine.apply_policies(backends, operation, opts)
  end

  defp select_backend([], _opts), do: {:error, :no_backend_available}

  defp select_backend([backend | _rest], _opts) do
    # Select highest priority backend
    {:ok, backend}
  end

  defp validate_consistency(_decisions) do
    # TODO: Check for conflicts (e.g., same resource routed to different backends)
    # For now, simple validation - returns :ok
    :ok
  end
end
