# HAR Network Architecture

**Purpose:** Distributed routing across multi-cloud, hybrid, and edge environments

HAR scales horizontally using Elixir/OTP's native distribution capabilities. This document describes how HAR nodes form clusters, communicate, and coordinate routing decisions.

## Network Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                     HAR Cluster (Mesh Network)                  │
│                                                                  │
│  ┌──────────┐         ┌──────────┐         ┌──────────┐        │
│  │  HAR     │◄───────►│  HAR     │◄───────►│  HAR     │        │
│  │  Node 1  │         │  Node 2  │         │  Node 3  │        │
│  │  (Leader)│         │          │         │          │        │
│  └────┬─────┘         └────┬─────┘         └────┬─────┘        │
│       │                    │                    │               │
│       │   OTP Distribution (Erlang VM mesh)    │               │
│       └────────────────────┴────────────────────┘               │
│                            ↓                                    │
│                  ┌──────────────────┐                           │
│                  │   IPFS Cluster   │                           │
│                  │ (Config Storage) │                           │
│                  └──────────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
         ↓ (route to backends)
┌─────────────────────────────────────────────────────────────────┐
│                      Backend Targets                             │
│                                                                  │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐           │
│  │ Ansible │  │  Salt   │  │Terraform│  │   IoT   │           │
│  │ Control │  │ Master  │  │  Cloud  │  │ Devices │           │
│  │  Node   │  │         │  │         │  │         │           │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

## OTP Distribution

**Erlang VM Native Clustering:**

Each HAR node is an Erlang VM that can connect to other nodes via TCP/TLS.

**Node Naming:**
```elixir
# Start nodes with unique names
# Node 1
iex --name har1@192.168.1.10 --cookie secret_cookie -S mix

# Node 2
iex --name har2@192.168.1.11 --cookie secret_cookie -S mix

# Node 3
iex --name har3@192.168.1.12 --cookie secret_cookie -S mix
```

**Auto-Discovery with libcluster:**

```elixir
# config/config.exs
config :libcluster,
  topologies: [
    har_cluster: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        multicast_addr: "230.1.1.251",
        multicast_ttl: 1
      ]
    ]
  ]
```

**Discovery Strategies:**

1. **Gossip:** UDP multicast for local network
2. **Kubernetes:** K8s API for pod discovery
3. **DNS:** DNS SRV records
4. **Static:** Hardcoded node list

## Communication Patterns

### 1. Request/Response

**Client sends request, any node can handle:**

```elixir
# Client → HAR cluster
{:ok, result} = HAR.convert(:ansible, playbook, to: :salt)

# Internally:
# 1. Load balancer picks node (round-robin)
# 2. Node parses, routes, transforms
# 3. Returns result to client
```

### 2. Work Distribution

**Large jobs distributed across nodes:**

```elixir
# 10,000 operations to route
operations = parse_large_playbook(playbook)

# Partition across nodes
operations
|> Enum.chunk_every(div(length(operations), cluster_size()))
|> Enum.zip(Node.list())
|> Enum.map(fn {chunk, node} ->
  Task.Supervisor.async({HAR.TaskSupervisor, node}, fn ->
    HAR.ControlPlane.Router.route_batch(chunk)
  end)
end)
|> Task.await_many(timeout: 30_000)
|> Enum.flat_map(& &1)
```

### 3. State Synchronization

**Routing table shared across nodes:**

```elixir
# Leader loads new routing table
HAR.ControlPlane.RoutingTable.reload(yaml_path)

# Broadcast to all nodes
:rpc.multicall(Node.list(), HAR.ControlPlane.RoutingTable, :reload, [yaml_path])
```

**Using Horde (CRDT-based distributed registry):**

```elixir
defmodule HAR.Cluster.Registry do
  use Horde.Registry

  def start_link(_) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
  end

  def init(init_arg) do
    [members: members()]
    |> Keyword.merge(init_arg)
    |> Horde.Registry.init()
  end

  defp members do
    Enum.map([Node.self() | Node.list()], &{__MODULE__, &1})
  end
end
```

### 4. Event Broadcasting

**Telemetry events across cluster:**

```elixir
# Emit event on any node
:telemetry.execute([:har, :routing, :decision], %{latency: 5}, %{node: node()})

# Aggregator on each node collects local events
# Central dashboard queries all nodes
```

## Load Balancing

**Consistent Hashing:**

```elixir
defmodule HAR.Cluster.LoadBalancer do
  # Hash operation ID to determine target node
  def route_to_node(operation) do
    hash = :erlang.phash2(operation.id)
    nodes = [Node.self() | Node.list()] |> Enum.sort()
    index = rem(hash, length(nodes))
    Enum.at(nodes, index)
  end
end
```

**Benefits:**
- Same operation always routes to same node (cache hit)
- Adding/removing nodes only affects 1/N operations
- No central coordinator needed

**Round-Robin (Stateless):**

```elixir
defmodule HAR.Cluster.RoundRobin do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> 0 end, name: __MODULE__)
  end

  def next_node do
    nodes = [Node.self() | Node.list()]
    index = Agent.get_and_update(__MODULE__, fn i ->
      next = rem(i + 1, length(nodes))
      {i, next}
    end)
    Enum.at(nodes, index)
  end
end
```

## Fault Tolerance

### Node Failure Detection

**Erlang VM monitors connections:**

```elixir
# Monitor node connection
Node.monitor(:"har2@192.168.1.11", true)

# Receive notification on disconnect
receive do
  {:nodedown, node} ->
    Logger.warn("Node down: #{node}")
    remove_from_routing(node)
end
```

### Work Redistribution

**Task supervisor with fallback:**

```elixir
def route_with_fallback(operation) do
  primary_node = consistent_hash(operation)

  try do
    Task.Supervisor.async({HAR.TaskSupervisor, primary_node}, fn ->
      route_operation(operation)
    end)
    |> Task.await(5000)
  catch
    :exit, {:noproc, _} ->
      # Primary node down, try next node
      fallback_node = next_available_node(exclude: [primary_node])
      Task.Supervisor.async({HAR.TaskSupervisor, fallback_node}, fn ->
        route_operation(operation)
      end)
      |> Task.await(5000)
  end
end
```

### Distributed Supervision

**Horde.DynamicSupervisor for global process management:**

```elixir
# Start parser on any node
Horde.DynamicSupervisor.start_child(
  HAR.ParserSupervisor,
  {HAR.DataPlane.AnsibleParser, config}
)

# If node crashes, parser restarts on another node
```

## Multi-Region Deployment

```
┌──────────────────────────────────────────────────────────────┐
│                       Region: US-East                         │
│  ┌──────┐  ┌──────┐  ┌──────┐                                │
│  │ HAR  │  │ HAR  │  │ HAR  │                                │
│  │ Node │  │ Node │  │ Node │                                │
│  └──────┘  └──────┘  └──────┘                                │
└───────────────────────┬──────────────────────────────────────┘
                        │ (WAN link)
┌───────────────────────┴──────────────────────────────────────┐
│                       Region: EU-West                         │
│  ┌──────┐  ┌──────┐  ┌──────┐                                │
│  │ HAR  │  │ HAR  │  │ HAR  │                                │
│  │ Node │  │ Node │  │ Node │                                │
│  └──────┘  └──────┘  └──────┘                                │
└──────────────────────────────────────────────────────────────┘
```

**Latency-Aware Routing:**

```elixir
# Route to nearest region
def route_with_latency(operation) do
  nodes_by_latency = [Node.self() | Node.list()]
  |> Enum.map(fn node ->
    {node, measure_latency(node)}
  end)
  |> Enum.sort_by(fn {_node, latency} -> latency end)

  {nearest_node, _latency} = List.first(nodes_by_latency)
  route_to(operation, nearest_node)
end
```

**Data Sovereignty:**

```elixir
# Policy: EU data must stay in EU region
%Policy{
  name: :eu_data_residency,
  match: %{data_region: "eu"},
  require: %{node: %{region: "eu"}},
  action: :enforce
}
```

## Security

### Encrypted Distribution

**TLS for inter-node communication:**

```elixir
# config/runtime.exs
config :kernel,
  inet_dist_use_interface: {0, 0, 0, 0},
  inet_dist_listen_min: 9100,
  inet_dist_listen_max: 9199

# Use TLS distribution
# erl -proto_dist inet_tls -ssl_dist_optfile /path/to/ssl.conf
```

**SSL Config:**
```erlang
% ssl.conf
[{server, [
  {certfile, "/path/to/server.crt"},
  {keyfile, "/path/to/server.key"},
  {cacertfile, "/path/to/ca.crt"},
  {verify, verify_peer},
  {fail_if_no_peer_cert, true}
]}].
```

### Node Authentication

**Shared secret (cookie) + TLS certs:**

```elixir
# Cookie prevents unauthorized nodes from joining
Node.set_cookie(:secret_cookie_from_vault)

# TLS ensures encrypted communication
# Mutual TLS ensures both sides authenticated
```

### Network Segmentation

```
┌──────────────────────────────────────────────────────────┐
│              Management Network (VPN)                     │
│  HAR nodes communicate via secure overlay                │
│  10.0.1.0/24                                             │
└──────────────────────────────────────────────────────────┘
         ↓
┌──────────────────────────────────────────────────────────┐
│              Backend Network (Isolated)                   │
│  Ansible, Salt, etc. on separate subnet                  │
│  10.0.2.0/24                                             │
└──────────────────────────────────────────────────────────┘
```

## Kubernetes Deployment

**StatefulSet for stable network identity:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: har
  labels:
    app: har
spec:
  ports:
  - port: 4000
    name: http
  - port: 9100
    name: epmd
  clusterIP: None
  selector:
    app: har
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: har
spec:
  serviceName: har
  replicas: 3
  selector:
    matchLabels:
      app: har
  template:
    metadata:
      labels:
        app: har
    spec:
      containers:
      - name: har
        image: har:latest
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: RELEASE_DISTRIBUTION
          value: "name"
        - name: RELEASE_NODE
          value: "har@$(POD_IP)"
        ports:
        - containerPort: 4000
          name: http
        - containerPort: 9100
          name: epmd
```

**libcluster Kubernetes strategy:**

```elixir
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [
        mode: :ip,
        kubernetes_node_basename: "har",
        kubernetes_selector: "app=har",
        kubernetes_namespace: "default",
        polling_interval: 10_000
      ]
    ]
  ]
```

## Performance Tuning

**TCP Buffer Sizes:**
```elixir
# Increase for high-throughput networks
config :kernel,
  inet_default_connect_options: [{:sndbuf, 256 * 1024}, {:recbuf, 256 * 1024}]
```

**Distribution Buffer:**
```bash
# Increase distributed send buffer
erl +zdbbl 32768
```

**Scheduler Binding:**
```bash
# Bind schedulers to CPU cores
erl +sbt db +swt very_low
```

## Monitoring

**Cluster Health Metrics:**

```elixir
# Node count
:telemetry.execute([:har, :cluster, :size], %{nodes: length(Node.list()) + 1})

# Inter-node latency
:telemetry.execute([:har, :cluster, :latency], %{latency_ms: latency}, %{target: node})

# Message queue length (backpressure indicator)
:telemetry.execute([:har, :cluster, :queue_len], %{messages: queue_len})
```

**Dashboard Visualization:**
- Cluster topology graph (nodes + connections)
- Request distribution (ops/sec per node)
- Failover events (node down/up)
- Network latency heatmap

## Scaling Guidelines

| Workload | Nodes | Rationale |
|----------|-------|-----------|
| Development | 1 | Single node sufficient |
| Small prod | 3 | HA with quorum |
| Medium prod | 5-10 | Load distribution |
| Large prod | 10-50 | Geographic distribution |
| Massive scale | 50-100 | Partition by region/team |

**When to Add Nodes:**
- CPU > 70% sustained
- Request latency > SLA
- Geographic expansion
- Fault tolerance requirements

**When NOT to Add Nodes:**
- Memory pressure (scale vertically first)
- Network bottleneck (optimize serialization)
- Database bottleneck (not HAR-specific)

## Edge Deployment

**Single-Binary Elixir Releases:**

```bash
# Build standalone release
MIX_ENV=prod mix release

# Deploy to edge device
scp _build/prod/rel/har/bin/har edge-device:/usr/local/bin/
ssh edge-device 'har start'
```

**Lightweight Mode:**
```elixir
# Disable web UI, metrics for resource-constrained devices
config :har,
  edge_mode: true,
  web_enabled: false,
  telemetry_enabled: false
```

## Future Enhancements

1. **Global Load Balancing:** Anycast routing to nearest cluster
2. **Mesh VPN:** Automatic overlay network (Tailscale, WireGuard)
3. **Multi-Cluster Federation:** Route between independent clusters
4. **Smart Caching:** Distributed cache with CRDTs
5. **Traffic Mirroring:** Shadow traffic for testing

## Summary

HAR's network architecture leverages Elixir/OTP's battle-tested distribution:
- **Mesh networking:** Erlang VM native clustering
- **Fault tolerance:** Automatic failover and work redistribution
- **Scalability:** Horizontal scaling with consistent hashing
- **Security:** TLS encryption + mutual authentication
- **Flexibility:** Deploy standalone, clustered, or multi-region

**Next:** See IOT_IIOT_ARCHITECTURE.md for device-scale routing.
