# HAR Control Plane Architecture

**Purpose:** Routing decisions, backend selection, policy enforcement

The control plane is the "brain" of HAR - it decides WHERE operations should be routed, WHO can execute them, and HOW to optimize execution.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Control Plane                            │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   Routing    │  │   Policy     │  │   Health     │      │
│  │   Engine     │  │   Engine     │  │   Checker    │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                 │                 │               │
│         └─────────────────┴─────────────────┘               │
│                           ↓                                 │
│                  ┌─────────────────┐                        │
│                  │  Routing Table  │                        │
│                  │  (Pattern Match)│                        │
│                  └─────────────────┘                        │
└─────────────────────────────────────────────────────────────┘
         ↓ (routing decisions)
┌─────────────────────────────────────────────────────────────┐
│                    Data Plane                               │
│              (transformation execution)                     │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. Routing Engine

**Responsibility:** Select optimal backend for each operation

**Implementation:** `HAR.ControlPlane.Router` (GenServer)

**Algorithm:**
```elixir
def route(semantic_graph, opts) do
  # 1. Extract operations from graph
  operations = Graph.vertices(semantic_graph)

  # 2. For each operation, pattern match against routing table
  routing_decisions = Enum.map(operations, fn op ->
    backends = RoutingTable.match(op)
    |> filter_by_health()
    |> filter_by_policy(opts)
    |> sort_by_priority()

    %RoutingDecision{
      operation: op,
      backend: List.first(backends),
      alternatives: backends,
      reason: :pattern_match
    }
  end)

  # 3. Validate no conflicts (e.g., same resource routed to different backends)
  validate_consistency(routing_decisions)

  # 4. Return routing plan
  {:ok, %RoutingPlan{decisions: routing_decisions, graph: semantic_graph}}
end
```

**Pattern Matching:**

Routing table is YAML-based, loaded at startup:
```yaml
routes:
  # Route Debian package installs to apt backend
  - pattern:
      operation: package.install
      target:
        os: debian
    backends:
      - name: apt
        priority: 100
      - name: ansible.apt
        priority: 50

  # Route IoT device configs to minimal systemd
  - pattern:
      operation: service.*
      target:
        device_type: iot
    backends:
      - name: systemd_minimal
        priority: 100
      - name: salt.service
        priority: 50

  # Fallback: use ansible for anything
  - pattern:
      operation: "*"
    backends:
      - name: ansible
        priority: 10
```

**Matching Logic:**
```elixir
defmodule HAR.ControlPlane.RoutingTable do
  def match(operation) do
    routes()
    |> Enum.filter(fn route ->
      pattern_matches?(route.pattern, operation)
    end)
    |> Enum.flat_map(& &1.backends)
    |> Enum.sort_by(& &1.priority, :desc)
  end

  defp pattern_matches?(pattern, operation) do
    operation_matches?(pattern.operation, operation.type) and
    target_matches?(pattern.target, operation.target)
  end

  defp operation_matches?(pattern, type) do
    case pattern do
      "*" -> true
      ^type -> true
      glob when is_binary(glob) -> wildcard_match?(glob, to_string(type))
      _ -> false
    end
  end
end
```

### 2. Policy Engine

**Responsibility:** Enforce security, compliance, cost constraints

**Implementation:** `HAR.ControlPlane.PolicyEngine` (GenServer)

**Policy Types:**

1. **Security Policies**
```elixir
# Example: Industrial systems must use high-security backends
%Policy{
  name: :industrial_security,
  match: %{target: %{device_type: "industrial"}},
  require: %{backend: %{security_tier: :high}},
  action: :enforce
}
```

2. **Compliance Policies**
```elixir
# Example: PCI-DSS requires audit logging
%Policy{
  name: :pci_audit,
  match: %{tags: ["pci-dss"]},
  require: %{backend: %{audit_enabled: true}},
  action: :enforce
}
```

3. **Cost Policies**
```elixir
# Example: Prefer free backends for dev environments
%Policy{
  name: :dev_cost_optimize,
  match: %{target: %{environment: "dev"}},
  prefer: %{backend: %{cost: 0}},
  action: :optimize
}
```

4. **Performance Policies**
```elixir
# Example: Critical operations need low-latency backends
%Policy{
  name: :critical_performance,
  match: %{priority: :critical},
  prefer: %{backend: %{latency_p99: {:lt, 10}}},
  action: :optimize
}
```

**Policy Evaluation:**
```elixir
defmodule HAR.ControlPlane.PolicyEngine do
  def evaluate(routing_decisions, policies) do
    Enum.map(routing_decisions, fn decision ->
      applicable_policies = Enum.filter(policies, &matches?(&1, decision.operation))

      case apply_policies(decision, applicable_policies) do
        {:ok, updated_decision} -> updated_decision
        {:error, :policy_violation} = error -> error
      end
    end)
  end

  defp apply_policies(decision, policies) do
    Enum.reduce_while(policies, {:ok, decision}, fn policy, {:ok, decision} ->
      case policy.action do
        :enforce -> enforce_policy(decision, policy)
        :optimize -> optimize_policy(decision, policy)
        :warn -> warn_policy(decision, policy)
      end
    end)
  end
end
```

### 3. Health Checker

**Responsibility:** Monitor backend availability and performance

**Implementation:** `HAR.ControlPlane.HealthChecker` (GenServer with periodic polling)

**Health Checks:**
```elixir
defmodule HAR.ControlPlane.HealthChecker do
  use GenServer

  # Poll backends every 10 seconds
  @poll_interval 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_check()
    {:ok, %{backends: %{}, last_check: nil}}
  end

  def handle_info(:check_health, state) do
    backend_health = backends()
    |> Enum.map(fn backend ->
      {backend.name, check_backend(backend)}
    end)
    |> Map.new()

    schedule_check()
    {:noreply, %{state | backends: backend_health, last_check: DateTime.utc_now()}}
  end

  defp check_backend(backend) do
    case backend.type do
      :local -> check_local(backend)
      :remote -> check_remote(backend)
      :cloud -> check_cloud(backend)
    end
  end

  defp check_remote(backend) do
    case :httpc.request(:get, {"#{backend.url}/health", []}, [], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        %HealthStatus{status: :healthy, latency: measure_latency(backend)}
      _ ->
        %HealthStatus{status: :unhealthy, latency: nil}
    end
  end
end
```

**Health Metrics:**
- **Status:** `:healthy`, `:degraded`, `:unhealthy`
- **Latency:** p50, p99, p999 (from recent requests)
- **Error Rate:** % of failed operations
- **Capacity:** % of max concurrent operations
- **Version:** Backend software version

**Circuit Breaker:**
```elixir
# If backend fails 5 times in 30 seconds, mark unhealthy for 60 seconds
%CircuitBreaker{
  failure_threshold: 5,
  window_seconds: 30,
  recovery_seconds: 60
}
```

### 4. Routing Table Manager

**Responsibility:** Load, validate, reload routing configuration

**Implementation:** `HAR.ControlPlane.RoutingTable` (ETS-backed GenServer)

**Table Structure:**
```elixir
# ETS table for fast pattern matching
:ets.new(:routing_table, [:named_table, :ordered_set, read_concurrency: true])

# Insert routes sorted by specificity (most specific first)
:ets.insert(:routing_table, {specificity_score(route), route})

# Lookup matches
:ets.foldl(fn {_score, route}, acc ->
  if matches?(route, operation), do: [route | acc], else: acc
end, [], :routing_table)
```

**Hot Reload:**
```elixir
# Reload routing table without restarting
HAR.ControlPlane.RoutingTable.reload("/path/to/new_table.yaml")

# Validates YAML before applying
# Atomic swap (no partial updates)
# Emits telemetry event
```

## Distributed Control Plane

**Challenge:** Multiple HAR nodes need consistent routing decisions

**Solution:** Distributed consensus using Horde (CRDT-based)

```elixir
defmodule HAR.ControlPlane.DistributedRouter do
  use Horde.DynamicSupervisor

  # Each node runs routing engine
  # Shared state via CRDTs
  # Eventual consistency (AP in CAP theorem)

  def start_link(opts) do
    Horde.DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    Horde.DynamicSupervisor.init(strategy: :one_for_one, members: :auto)
  end
end
```

**Routing Table Synchronization:**
```elixir
# Leader node reloads routing table
HAR.ControlPlane.RoutingTable.reload(yaml_path)

# Broadcast to cluster
:pg.get_members(:har_cluster, :routing_table)
|> Enum.each(fn pid ->
  send(pid, {:reload_routing_table, yaml_path})
end)
```

## Telemetry & Observability

**Metrics Emitted:**
```elixir
# Routing decision latency
:telemetry.execute(
  [:har, :control_plane, :routing, :decision],
  %{latency: latency_ms},
  %{operation_type: op.type}
)

# Policy violations
:telemetry.execute(
  [:har, :control_plane, :policy, :violation],
  %{count: 1},
  %{policy: policy.name, operation: op.id}
)

# Backend health changes
:telemetry.execute(
  [:har, :control_plane, :health, :change],
  %{status: :unhealthy},
  %{backend: backend.name}
)
```

**Dashboards:**
- Routing decision latency (p50, p99, p999)
- Backend health status (visual map)
- Policy violation trends
- Backend selection distribution

## Example Flow

```elixir
# 1. Receive semantic graph from parser
graph = %Graph{
  vertices: [
    %Operation{id: "op1", type: :package_install, target: %{os: "debian"}}
  ]
}

# 2. Route operations
{:ok, plan} = HAR.ControlPlane.Router.route(graph, target: :salt)

# plan = %RoutingPlan{
#   decisions: [
#     %RoutingDecision{
#       operation: %Operation{id: "op1", ...},
#       backend: %Backend{name: "apt", type: :local},
#       alternatives: [%Backend{name: "ansible.apt", ...}],
#       reason: :pattern_match,
#       policies_applied: [:industrial_security]
#     }
#   ]
# }

# 3. Hand off to data plane for transformation
HAR.DataPlane.Transformer.transform(plan)
```

## Performance Optimization

**Caching:**
```elixir
# Cache routing decisions for identical operations
# TTL: 60 seconds (routing table changes invalidate)
%Cache{
  key: hash(operation),
  value: routing_decision,
  ttl: 60
}
```

**Batching:**
```elixir
# Route 1000 operations in single pass
# Shared pattern matching (amortized cost)
route_batch(operations) do
  compiled_patterns = compile_routing_table()
  Enum.map(operations, &fast_match(&1, compiled_patterns))
end
```

**Parallelization:**
```elixir
# Route operations in parallel (no shared state)
operations
|> Task.async_stream(&route_single/1, max_concurrency: System.schedulers_online())
|> Enum.map(&elem(&1, 1))
```

## Error Handling

**Routing Failures:**
```elixir
case route(graph) do
  {:ok, plan} -> plan
  {:error, :no_backend_available} ->
    # Retry with fallback backends
    route(graph, allow_fallback: true)
  {:error, :policy_violation} ->
    # Log violation, return error to user
    Logger.error("Policy violation: #{inspect(violation)}")
    {:error, violation}
end
```

**Supervision Tree:**
```
ControlPlaneSupervisor
├── RoutingEngine (restart: :permanent)
├── PolicyEngine (restart: :permanent)
├── HealthChecker (restart: :permanent)
└── RoutingTable (restart: :permanent)
```

If any component crashes, supervisor restarts it without affecting others.

## Future Enhancements

1. **ML-Based Routing:** Learn optimal backends from historical metrics
2. **Multi-Region Routing:** Consider network latency, data sovereignty
3. **Cost Optimization:** Automatic backend selection based on pricing
4. **A/B Testing:** Route % of traffic to new backends for validation
5. **Traffic Shaping:** Rate limiting, priority queues

## Summary

The control plane is HAR's decision-making layer. By separating routing logic from transformation execution, we achieve:
- **Flexibility:** Change routing without modifying parsers/transformers
- **Scalability:** Distributed routing across cluster
- **Reliability:** Health checking prevents routing to dead backends
- **Governance:** Policy enforcement for security/compliance
- **Observability:** Rich telemetry for debugging/optimization

**Next:** See DATA_PLANE_ARCHITECTURE.md for transformation details.
