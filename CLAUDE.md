# HAR - Hybrid Automation Router

## Project Vision

**Think BGP for infrastructure automation.** HAR treats configuration management like network packet routing - it parses configs from any IaC tool (Ansible, Salt, Terraform, bash), extracts semantic operations, and routes/transforms them to any target format.

## Core Innovation

**Network router architecture for Infrastructure-as-Code:**
- Semantic understanding of infrastructure operations (install package, create user, configure service)
- Distributed routing decisions across multi-cloud/hybrid/edge environments
- Tool-agnostic translation layer (write once, deploy anywhere)
- Scale from servers → IoT sensors → industrial robots using unified control plane

## Architecture Decisions

### Technology Stack

**Primary: Elixir/OTP**
- Fault tolerance via supervision trees ("let it crash" philosophy)
- Native distributed computing (OTP distribution)
- Pattern matching for routing logic
- Proven at scale (WhatsApp, Discord)

**Why NOT Haskell:** Too complex, slower development velocity
**Optional Components:**
- Logtalk: Pattern-based routing rules
- Julia: ML-based routing optimization
- IPFS: Content-addressed config storage

### Core Architecture

**Control Plane / Data Plane Separation:**
```
┌─────────────────────────────────────────┐
│  Control Plane (Routing Decisions)      │
│  - Pattern matching                     │
│  - Backend selection                    │
│  - Policy enforcement                   │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│  Data Plane (Transformation)            │
│  - Parse IaC → Semantic Graph           │
│  - Route operations                     │
│  - Generate target format               │
└─────────────────────────────────────────┘
```

**Semantic Graph as IR:**
- NOT Cue/Nickel (too opinionated for cross-tool translation)
- Directed graph: Operations (nodes) → Dependencies (edges)
- Platform-agnostic representation
- Enables intelligent routing and optimization

### Scale: From Servers to IoT/IIoT

**IPv6 + MAC Addressing:**
- IPv6 subnets for device type classification:
  - `2001:db8:1::/48` - Servers
  - `2001:db8:2::/48` - IoT sensors
  - `2001:db8:3::/48` - Industrial robots
- MAC addresses for device discovery (NOT auth - spoofable!)
- Billions of devices supported

**DNS for Device Identity:**
- HARDEV resource record type (or TXT fallback)
- Advertise device capabilities
- Service discovery at scale

### Security Model (Multi-Layer)

**Critical Insight: MAC spoofing is real - use certificates for auth, MAC only for discovery**

Security tiers:
1. **Dev environments:** Low (self-signed certs)
2. **IoT devices:** Medium (device certs + rate limiting)
3. **Industrial systems:** High (mutual TLS + air-gapped segments)
4. **Critical infrastructure:** Maximum (HSM-backed certs + formal verification)

Primary auth: **TLS certificates**
Secondary binding: MAC addresses (discovery/binding only)
Audit: All routing decisions logged immutably (IPFS)

### IPFS Integration

**Content-Addressed Configurations:**
- Immutable versioning (CID = hash of config)
- Global deduplication (same config = same hash)
- Verifiable deployments (integrity checking)
- Offline-capable (distributed CDN for configs)

## Project Structure

```
hybrid-automation-router/
├── lib/                    # Elixir source code
│   ├── har/                # Main application
│   │   ├── control_plane/  # Routing engine
│   │   ├── data_plane/     # Parsers & transformers
│   │   ├── semantic/       # Semantic graph models
│   │   ├── security/       # Auth & encryption
│   │   └── ipfs/           # Content addressing
│   └── har.ex              # Application entry
├── test/                   # Test suites
├── config/                 # Configuration files
├── docs/                   # Architecture documentation
│   ├── FINAL_ARCHITECTURE.md
│   ├── CONTROL_PLANE_ARCHITECTURE.md
│   ├── HAR_NETWORK_ARCHITECTURE.md
│   ├── IOT_IIOT_ARCHITECTURE.md
│   ├── HAR_SECURITY.md
│   ├── STANDARDIZATION_STRATEGY.md
│   └── SELF_HOSTED_DEPLOYMENT.md
├── priv/                   # Static assets, routing tables
│   └── routing_table.yaml
└── examples/               # Example configs
    ├── ansible/
    ├── salt/
    └── terraform/
```

## Development Roadmap

### Phase 1: POC (3-6 months) - **CURRENT**
- [x] Architecture documentation
- [ ] Elixir/Mix project setup
- [ ] Semantic graph models
- [ ] Ansible/Salt/Terraform parsers
- [ ] Basic routing engine
- [ ] CLI demo (Ansible → Salt transformation)
- [ ] Self-hosted Podman deployment

### Phase 2: Community (6-12 months)
- [ ] Plugin architecture for parsers
- [ ] Web dashboard (routing visualization)
- [ ] Distributed routing (multi-node OTP cluster)
- [ ] ML-based routing optimization
- [ ] Performance benchmarks vs native tools

### Phase 3: Standardization (1-2 years)
- [ ] Draft IETF RFC specification
- [ ] Reference implementation compliance tests
- [ ] HAR Foundation governance
- [ ] Trademark protection
- [ ] Multi-vendor adoption

## Standardization Strategy

**Goal: Prevent vendor lock-in, become infrastructure standard**

Protections:
1. **MIT License:** Maximum accessibility
2. **Trademark:** "HAR" and logo protected
3. **Foundation:** Neutral governance (Linux Foundation model)
4. **IETF RFC:** Protocol specification standard
5. **Compliance Tests:** Certification for implementations

## Development Guidelines

### Elixir/OTP Principles

**"Let it crash" philosophy:**
- Supervision trees isolate failures
- If Salt parser crashes → only it restarts (not entire router)
- No defensive programming - fail fast, recover automatically

**Pattern Matching:**
```elixir
# Route based on semantic operation
def route(%Operation{type: :package_install, target: target}) do
  case target do
    %{os: "debian"} -> :apt_backend
    %{os: "redhat"} -> :yum_backend
    %{os: "alpine"} -> :apk_backend
  end
end
```

### Validation Strategy

**No Haskell needed - Elixir tools sufficient:**
- Dialyzer: Static type checking
- Pattern matching: Exhaustive case coverage
- Property testing: QuickCheck-style (PropEr/StreamData)
- Contract specs: @spec annotations

### Testing

```bash
# Unit tests
mix test

# Integration tests
mix test --only integration

# Property tests
mix test --only property

# Dialyzer static analysis
mix dialyzer
```

### Code Style

- Follow Elixir conventions (snake_case, 2-space indent)
- Document public functions with @doc
- Use @spec for type contracts
- GenServer for stateful processes
- Supervisor for fault tolerance

## Key Concepts

### Semantic Operations

Infrastructure operations abstracted from tool syntax:
- **Package Management:** Install, remove, update
- **User Management:** Create, delete, modify permissions
- **Service Control:** Start, stop, restart, enable
- **File Operations:** Create, template, copy, permissions
- **Network Config:** Interfaces, routes, firewall rules

### Routing Table

Pattern-based mappings (YAML):
```yaml
routes:
  - pattern:
      operation: package.install
      os: debian
    backends:
      - type: apt
        priority: 1
      - type: ansible.apt
        priority: 2

  - pattern:
      operation: service.restart
      device_type: iot
    backends:
      - type: systemd_minimal
        priority: 1
```

### Transformation Pipeline

```
Ansible YAML → Parser → Semantic Graph → Router → Salt SLS
     ↓                      ↓               ↓          ↓
   Source IR          Normalized IR    Decision   Target Format
```

## Deployment

### Self-Hosted (Podman + Salt)

```bash
# Start HAR cluster (3 nodes)
podman-compose up -d

# Nodes auto-discover via OTP distribution
# Load balancing via consistent hashing
# Configs stored in IPFS cluster
```

### Cloud Native (Kubernetes)

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: har-cluster
spec:
  replicas: 3
  serviceName: har
  # Elixir nodes cluster via libcluster
```

## Performance Targets

- **Routing Decision:** <10ms (99th percentile)
- **Ansible→Salt Transform:** <100ms for 1000 tasks
- **Throughput:** 10k operations/sec per node
- **Scale:** Linear with node count (OTP distribution)

## Security Considerations

**Input Validation:**
- All parsed configs sandboxed
- No arbitrary code execution
- Resource limits (memory, CPU per parse)

**Credential Storage:**
- Secrets never in semantic graph
- Reference tokens only (vault integration)
- Audit log all secret access

**Rate Limiting:**
- Per-client quotas
- DDoS protection (SYN cookies)
- Circuit breakers for backends

## Contributing

### Getting Started

```bash
# Install Elixir/OTP
asdf install erlang 26.0
asdf install elixir 1.15

# Clone and setup
git clone https://github.com/yourusername/hybrid-automation-router
cd hybrid-automation-router
mix deps.get
mix test

# Run locally
iex -S mix
```

### Adding a Parser

1. Implement `HAR.DataPlane.Parser` behaviour
2. Add to supervision tree
3. Register in routing table
4. Write property tests

### Architecture Decisions

Document significant choices in `docs/adr/` (Architecture Decision Records)

## Future Extensions

- **ML Routing:** Learn optimal backend selection from metrics
- **Multi-Region:** Global routing with latency awareness
- **Policy Engine:** OPA integration for compliance
- **Time-Travel Debugging:** Replay routing decisions from IPFS logs
- **Formal Verification:** TLA+ specs for critical paths

## Notes for Claude Code

**Current Status:** Early development - architecture finalized, implementation starting

**Key Priorities:**
1. Working Elixir prototype (parsers + routing)
2. Demonstrate value (Ansible→Salt transformation)
3. IPFS integration (content addressing)
4. Documentation for RFC submission

**Decision Philosophy:**
- Pragmatic over perfect (iterate quickly)
- Proven tech over cutting-edge (Elixir not Haskell)
- Standards-based (prevent lock-in)
- Scale-first design (IoT/IIoT from day 1)

**When in Doubt:**
- Favor Elixir idioms (pattern matching, supervision trees)
- Add tests (property tests for parsers)
- Document in architecture docs
- Ask: "Does this prevent vendor lock-in?"

## License

MIT - Maximum accessibility, prevents nothing
