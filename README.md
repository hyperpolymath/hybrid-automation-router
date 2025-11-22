# HAR - Hybrid Automation Router

**Think BGP for infrastructure automation.** HAR treats configuration management like network packet routing - it parses configs from any IaC tool (Ansible, Salt, Terraform, bash), extracts semantic operations, and routes/transforms them to any target format.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Elixir](https://img.shields.io/badge/Elixir-1.15+-purple.svg)](https://elixir-lang.org/)

## Status

🚧 **Early Development (POC Phase)** 🚧

HAR is currently in active development. The architecture is finalized, and we're building the reference implementation. Contributions are welcome!

## Quick Start

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test

# Start interactive shell
iex -S mix

# Try a conversion
iex> {:ok, graph} = HAR.parse(:ansible, File.read!("examples/ansible/webserver.yml"))
iex> {:ok, salt_sls} = HAR.convert(:ansible, File.read!("examples/ansible/webserver.yml"), to: :salt)
iex> IO.puts(salt_sls)
```

## What is HAR?

HAR is an **infrastructure automation router** that provides:

- **Universal Interchange Format:** Convert between any IaC tools (Ansible ↔ Salt ↔ Terraform ↔ ...)
- **Semantic Understanding:** Understands infrastructure operations (install package, start service) independent of tool syntax
- **Intelligent Routing:** Routes operations to optimal backends based on target characteristics
- **IoT/IIoT Scale:** IPv6-based routing for billions of devices (servers → smart homes → industrial robots)
- **Tool Agnostic:** Write once, deploy anywhere - no vendor lock-in

## Core Concepts

### Semantic Graph (IR)

HAR's intermediate representation is a directed graph where:
- **Vertices** = Infrastructure operations (package.install, service.start, file.write)
- **Edges** = Dependencies (requires, notifies, sequential ordering)

```elixir
# Example semantic graph
%Graph{
  vertices: [
    %Operation{type: :package_install, params: %{package: "nginx"}},
    %Operation{type: :service_start, params: %{service: "nginx"}}
  ],
  edges: [
    %Dependency{from: "op1", to: "op2", type: :requires}
  ]
}
```

### Transformation Pipeline

```
Ansible YAML → Parser → Semantic Graph → Router → Transformer → Salt SLS
     ↓                      ↓               ↓          ↓
   Source IR          Normalized IR    Decision   Target Format
```

### Routing Engine

Pattern-based routing table matches operations to backends:

```yaml
# priv/routing_table.yaml
routes:
  - pattern:
      operation: package_install
      target:
        os: debian
    backends:
      - name: apt
        priority: 100
```

## Examples

### Convert Ansible to Salt

**Input (Ansible):**
```yaml
- name: Install nginx
  apt:
    name: nginx
    state: present

- name: Start nginx
  service:
    name: nginx
    state: started
```

**Output (Salt):**
```yaml
install_nginx:
  pkg.installed:
    - name: nginx

start_nginx:
  service.running:
    - name: nginx
    - enable: True
```

**Code:**
```elixir
{:ok, salt_config} = HAR.convert(:ansible, ansible_playbook, to: :salt)
```

### Parse and Route

```elixir
# Parse Ansible playbook
{:ok, graph} = HAR.parse(:ansible, playbook_yaml)

# Route to Salt backend
{:ok, routing_plan} = HAR.route(graph, target: :salt)

# Transform to Salt SLS
{:ok, salt_sls} = HAR.transform(routing_plan)
```

## Architecture

HAR uses Elixir/OTP for fault tolerance and distributed routing:

```
┌─────────────────────────────────────────────────────────────┐
│                    HAR Cluster (Mesh)                        │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐          │
│  │ HAR Node │◄────►│ HAR Node │◄────►│ HAR Node │          │
│  │    1     │      │    2     │      │    3     │          │
│  └──────────┘      └──────────┘      └──────────┘          │
└─────────────────────────────────────────────────────────────┘
         ↓                  ↓                  ↓
    [Backends: Ansible, Salt, Terraform, IoT agents, ...]
```

**Key Components:**
- **Control Plane:** Routing decisions, policy enforcement
- **Data Plane:** Parsing, transformation execution
- **IPFS Integration:** Content-addressed config storage
- **OTP Distribution:** Fault-tolerant clustering

See [docs/](./docs/) for detailed architecture documentation.

## Supported Formats

### Currently Implemented

| Format | Parse | Transform | Status |
|--------|-------|-----------|--------|
| Ansible | ✅ | ✅ | Alpha |
| Salt | ✅ | ✅ | Alpha |
| Terraform | 🚧 | 🚧 | In Progress |

### Planned

- Puppet
- Chef
- CFEngine
- Bash scripts
- Kubernetes manifests
- Docker Compose
- Pulumi
- Cloud-specific (CloudFormation, ARM templates)

## IoT/IIoT Support

HAR scales to billions of devices using IPv6 subnets for classification:

```
2001:db8:1::/48 - Servers (traditional IaC)
2001:db8:2::/48 - IoT devices (smart homes, wearables)
2001:db8:3::/48 - IIoT devices (factories, industrial robots)
```

**Security Tiers:**
- Dev: Self-signed certs
- IoT: Device certificates + TLS
- Industrial: Mutual TLS + VPN
- Critical Infrastructure: HSM-backed certs + dual approval

See [docs/IOT_IIOT_ARCHITECTURE.md](./docs/IOT_IIOT_ARCHITECTURE.md) for details.

## Development

### Prerequisites

- Elixir 1.15+
- Erlang/OTP 26+
- (Optional) IPFS for content addressing
- (Optional) Podman for deployment

### Setup

```bash
# Clone repository
git clone https://github.com/yourusername/hybrid-automation-router
cd hybrid-automation-router

# Install dependencies
mix deps.get

# Run tests
mix test

# Run with type checking
mix dialyzer

# Run linter
mix credo
```

### Project Structure

```
hybrid-automation-router/
├── lib/
│   ├── har/
│   │   ├── control_plane/   # Routing engine, policies
│   │   ├── data_plane/      # Parsers, transformers
│   │   └── semantic/        # Graph models
│   └── har.ex               # Main API
├── test/                    # Test suites
├── config/                  # Configuration
├── docs/                    # Architecture documentation
├── priv/                    # Static assets (routing table)
└── examples/                # Example configurations
```

## Roadmap

### Phase 1: POC (Current - Q1-Q2 2024)
- [x] Architecture documentation
- [x] Semantic graph models
- [x] Ansible/Salt parsers
- [x] Basic routing engine
- [x] Ansible/Salt transformers
- [ ] CLI interface
- [ ] IPFS integration
- [ ] Production deployment example

### Phase 2: Community (Q3 2024 - Q2 2025)
- [ ] Plugin architecture
- [ ] All major tool support (Terraform, Puppet, Chef)
- [ ] Web dashboard
- [ ] Performance optimization
- [ ] Production case studies

### Phase 3: Standardization (Q3 2025 - 2026)
- [ ] IETF RFC draft
- [ ] HAR Foundation
- [ ] Compliance certification
- [ ] Multi-vendor implementations

See [docs/STANDARDIZATION_STRATEGY.md](./docs/STANDARDIZATION_STRATEGY.md) for details.

## Documentation

- [FINAL_ARCHITECTURE.md](./docs/FINAL_ARCHITECTURE.md) - Core architecture decisions
- [CONTROL_PLANE_ARCHITECTURE.md](./docs/CONTROL_PLANE_ARCHITECTURE.md) - Routing engine design
- [DATA_PLANE_ARCHITECTURE.md](./docs/DATA_PLANE_ARCHITECTURE.md) - Parser/transformer details
- [HAR_NETWORK_ARCHITECTURE.md](./docs/HAR_NETWORK_ARCHITECTURE.md) - Distributed routing
- [IOT_IIOT_ARCHITECTURE.md](./docs/IOT_IIOT_ARCHITECTURE.md) - IoT/IIoT support
- [HAR_SECURITY.md](./docs/HAR_SECURITY.md) - Multi-tier security model
- [STANDARDIZATION_STRATEGY.md](./docs/STANDARDIZATION_STRATEGY.md) - Path to IETF RFC
- [SELF_HOSTED_DEPLOYMENT.md](./docs/SELF_HOSTED_DEPLOYMENT.md) - Production deployment

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

**Ways to contribute:**
- Add support for new IaC tools (parsers/transformers)
- Improve routing algorithms
- Write tests
- Improve documentation
- Report bugs
- Share use cases

## Community

- **GitHub Discussions:** [Ask questions, share ideas](https://github.com/yourusername/hybrid-automation-router/discussions)
- **Issues:** [Bug reports, feature requests](https://github.com/yourusername/hybrid-automation-router/issues)
- **Discord:** Coming soon
- **Twitter:** Coming soon

## License

MIT License - See [LICENSE](./LICENSE) for details.

**Philosophy:** Maximum accessibility, prevent vendor lock-in.

## Acknowledgments

- **Inspired by:** BGP (network routing), Babel (JavaScript transpilation)
- **Built with:** Elixir/OTP, IPFS, libgraph
- **Thanks to:** The open-source IaC community (Ansible, Salt, Terraform, Puppet, Chef teams)

## Citation

If you use HAR in research, please cite:

```bibtex
@software{har2024,
  title = {HAR: Hybrid Automation Router},
  author = {HAR Contributors},
  year = {2024},
  url = {https://github.com/yourusername/hybrid-automation-router}
}
```

---

**Status:** Early development | **License:** MIT | **Language:** Elixir

**Star this repo if you believe infrastructure automation should be tool-agnostic!** ⭐
