# HAR - Final Architecture Decision

**Date:** 2024-01
**Status:** Accepted
**Decision Makers:** Core Team

## Context

Infrastructure-as-Code (IaC) tools proliferate - Ansible, Salt, Terraform, Puppet, Chef, CFEngine, bash scripts, and more. Organizations often use multiple tools across teams, creating:

- **Lock-in:** Vendor/tool-specific configs can't be reused
- **Duplication:** Same infrastructure tasks rewritten for each tool
- **Complexity:** Multi-tool environments require expertise in each
- **Brittleness:** Migrations between tools require full rewrites

**Core Problem:** IaC lacks a universal interchange format and routing layer.

## Decision

Build HAR as an **infrastructure automation router** using network routing principles:

```
┌──────────────────────────────────────────────────────────────┐
│              Source Formats (Any IaC Tool)                   │
│  Ansible | Salt | Terraform | Puppet | Chef | Bash | ...    │
└────────────────────────┬─────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│                  Parser Layer (Data Plane)                   │
│  Format-specific parsers → Semantic Graph (IR)               │
└────────────────────────┬─────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│              Semantic Graph (Normalized IR)                  │
│  Operations: pkg.install, user.create, service.restart       │
│  Resources: files, templates, variables                      │
│  Dependencies: task ordering, conditionals                   │
└────────────────────────┬─────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│              Routing Engine (Control Plane)                  │
│  Pattern matching → Backend selection → Policy enforcement   │
└────────────────────────┬─────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│              Transformation Layer (Data Plane)               │
│  Semantic Graph → Target format generation                   │
└────────────────────────┬─────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────────────┐
│              Target Formats (Any IaC Tool)                   │
│  Ansible | Salt | Terraform | Puppet | Chef | Bash | ...    │
└──────────────────────────────────────────────────────────────┘
```

## Technology Stack

### Primary: Elixir/OTP

**Rationale:**
- **Fault Tolerance:** Supervision trees isolate failures (parser crash doesn't kill router)
- **Concurrency:** Lightweight processes (millions of concurrent operations)
- **Distribution:** Built-in clustering (no external coordination needed)
- **Pattern Matching:** Native support for routing logic
- **Production Proven:** WhatsApp (900M users on ~50 servers), Discord, Pinterest

**Alternatives Considered:**
- **Haskell:** Rejected - too complex, slower dev velocity, smaller talent pool
- **Go:** Rejected - lacks pattern matching, error handling verbose, no hot code swapping
- **Rust:** Rejected - too low-level, slow compile times, steep learning curve
- **Python:** Rejected - GIL limits concurrency, no true distribution, runtime errors

### Semantic Graph (IR)

**Format:** Directed acyclic graph (DAG) using `libgraph`

**Why NOT Cue/Nickel/Dhall:**
- Too opinionated (enforce schema, typing)
- Designed for config validation, not cross-tool translation
- Would inherit their limitations/opinions in output

**Graph Structure:**
```elixir
%Graph{
  vertices: [
    %Operation{
      id: "op_1",
      type: :package_install,
      params: %{name: "nginx", version: "1.18"},
      target: %{os: "debian", arch: "amd64"}
    },
    %Operation{
      id: "op_2",
      type: :service_start,
      params: %{name: "nginx"},
      target: %{os: "debian"}
    }
  ],
  edges: [
    %Dependency{from: "op_1", to: "op_2", type: :requires}
  ]
}
```

### Optional Components

**Logtalk (Pattern Rules):**
- Logic programming for complex routing rules
- Declarative policy specifications
- Integration via OS process calls

**Julia (ML Optimization):**
- Learn optimal backend selection from metrics
- Predict execution time/resource usage
- Clustering similar operations

**IPFS (Content Addressing):**
- Immutable config versioning (CID = hash)
- Global deduplication
- Offline-capable distribution
- Audit trail (who deployed what when)

## Core Principles

### 1. Separation of Concerns

**Control Plane** (routing decisions):
- Pattern matching against operation types
- Backend health checking
- Policy enforcement (security, compliance)
- Cost optimization

**Data Plane** (transformation execution):
- Parsing source configs
- Semantic graph construction
- Target format generation
- Validation

### 2. "Let It Crash" Philosophy

Use Elixir supervision trees:
```elixir
Supervisor
├── ControlPlaneSupervisor
│   ├── RoutingEngine (GenServer)
│   ├── PolicyEngine (GenServer)
│   └── HealthChecker (GenServer)
└── DataPlaneSupervisor
    ├── AnsibleParser (GenServer, restarts on crash)
    ├── SaltParser (GenServer, restarts on crash)
    └── TerraformParser (GenServer, restarts on crash)
```

If `AnsibleParser` crashes on malformed YAML → only it restarts, not entire system.

### 3. Tool Agnosticism

**No assumptions** about source or target format:
- Parsers are plugins (implement `Parser` behaviour)
- Transformers are plugins (implement `Transformer` behaviour)
- Semantic graph is universal IR
- Adding new tool = add parser + transformer

### 4. Scale-First Design

**From day one:**
- IPv6 addressing (billions of devices)
- Distributed routing (OTP clustering)
- Horizontal scaling (add nodes, not resources)
- Content addressing (IPFS for configs)

### 5. Standardization Path

**Goal:** HAR becomes infrastructure standard (like BGP for networks)

**Protections:**
1. **MIT License:** Maximum accessibility
2. **Trademark:** "HAR" name/logo protected
3. **Foundation:** Neutral governance
4. **IETF RFC:** Protocol specification
5. **Compliance Tests:** Vendor certification

## Validation Strategy

**No Haskell-level type system needed** - Elixir provides sufficient guarantees:

1. **Dialyzer:** Static analysis finds type errors
2. **Pattern Matching:** Exhaustive case coverage
3. **Specs:** @spec annotations for contracts
4. **Property Testing:** QuickCheck-style with StreamData
5. **Integration Tests:** Real-world config transformations

Example:
```elixir
@spec parse(atom(), String.t()) :: {:ok, Graph.t()} | {:error, term()}
def parse(format, content) when is_atom(format) and is_binary(content) do
  # Dialyzer ensures return matches spec
  # Pattern match ensures valid format atom
end
```

## Performance Targets

| Metric | Target | Rationale |
|--------|--------|-----------|
| Routing Decision | <10ms (p99) | Human-imperceptible |
| Parse 1000 tasks | <100ms | Interactive feedback |
| Transform 1000 tasks | <100ms | Interactive feedback |
| Throughput/node | 10k ops/sec | Production workloads |
| Horizontal scaling | Linear | OTP distribution |
| Max cluster size | 100+ nodes | Enterprise scale |

## Security Considerations

**See HAR_SECURITY.md for full details.**

Key decisions:
- **TLS certificates** for authentication (NOT MAC addresses - spoofable)
- **MAC addresses** for discovery/binding only
- **Multi-tier security** (dev → IoT → industrial → critical)
- **Immutable audit logs** (IPFS for routing decisions)
- **Sandboxed parsing** (resource limits, no arbitrary code exec)

## Deployment Models

### 1. Single Node (Development)
```bash
iex -S mix
```

### 2. Self-Hosted Cluster (Podman)
```bash
podman-compose up -d
# 3 nodes, auto-discovery, IPFS storage
```

### 3. Cloud Native (Kubernetes)
```yaml
StatefulSet: har-cluster (3 replicas)
Service: har (load balancer)
ConfigMap: routing_table.yaml
Secret: TLS certs
```

### 4. Edge/IoT (Single Binary)
```bash
# Elixir releases - no runtime dependency
./har start
```

## Migration Path

### Phase 1: POC (3-6 months)
- Elixir project setup
- Semantic graph models
- Ansible/Salt parsers
- Basic routing engine
- CLI demo

### Phase 2: Production (6-12 months)
- All major tools supported
- Web dashboard
- Distributed routing
- Performance optimization
- Plugin architecture

### Phase 3: Standardization (1-2 years)
- IETF RFC draft
- Multi-vendor adoption
- Foundation governance
- Compliance certification

## Open Questions

1. **Lossy transformations:** How to handle tool-specific features?
   - **Answer:** Metadata preservation + warnings

2. **Circular dependencies:** How to detect/handle in semantic graph?
   - **Answer:** Topological sort validation

3. **State management:** How to track "what's deployed where"?
   - **Answer:** Phase 2 feature (state backend abstraction)

4. **Breaking changes:** How to version semantic graph format?
   - **Answer:** SemVer + migration guides

## References

- **Network Routing:** BGP (RFC 4271), OSPF (RFC 2328)
- **Semantic Networks:** RDF, OWL, property graphs
- **Distributed Systems:** Erlang/OTP Design Principles
- **IaC Tools:** Ansible, Salt, Terraform, Puppet documentation
- **Content Addressing:** IPFS whitepaper, Git internals

## Conclusion

HAR applies proven network routing principles to infrastructure automation. By using Elixir/OTP for fault tolerance, a semantic graph for tool-agnostic representation, and standardization for vendor neutrality, HAR can become the "BGP for infrastructure automation."

**Next Steps:** Begin Phase 1 implementation (semantic models + parsers).
