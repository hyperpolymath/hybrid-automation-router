;; SPDX-License-Identifier: MPL-2.0
;; STATE.scm - Project state for HAR (Hybrid Automation Router)

(state
  (metadata
    (version "0.1.0")
    (schema-version "1.0")
    (created "2025-01-03")
    (updated "2026-01-10")
    (project "hybrid-automation-router")
    (repo "hyperpolymath/hybrid-automation-router"))

  (project-context
    (name "Hybrid Automation Router")
    (tagline "BGP for infrastructure automation")
    (tech-stack
      ("Elixir/OTP" "Primary language - fault-tolerant distributed systems")
      ("libgraph" "Semantic graph IR")
      ("yaml_elixir" "YAML parsing")
      ("libcluster" "Distributed clustering")
      ("horde" "Distributed process registry")))

  (current-position
    (phase "alpha")
    (overall-completion 40)
    (components
      (semantic-graph 80)
      (ansible-parser 85)
      (salt-parser 70)
      (terraform-parser 0)
      (ansible-transformer 70)
      (salt-transformer 70)
      (terraform-transformer 0)
      (routing-engine 50)
      (routing-table 70)
      (ipfs-integration 10)
      (security-manager 10)
      (web-endpoint 10)
      (telemetry 60)
      (ci-cd 100))
    (working-features
      ("Elixir project compiles" "mix compile succeeds with warnings only")
      ("Semantic Graph IR" "Operations, Dependencies, Graph structures")
      ("Ansible YAML parsing" "Parses playbooks to semantic graph with correct service types")
      ("Salt SLS parsing" "Parses states to semantic graph")
      ("YAML output" "YamlFormatter for serializing configs")
      ("Routing table" "GenServer with YAML-based patterns")
      ("Basic routing logic" "Pattern matching to backends")
      ("Telemetry infrastructure" "Metrics and logging")
      ("CI/CD workflows" "All GitHub Actions SHA-pinned")
      ("Test suite" "61 tests passing (59 unit + 2 doctests)")))

  (route-to-mvp
    (milestone "0.2.0 - Parser Completion"
      (items
        ("Add Terraform HCL parser")
        ("Add JSON output format")))
    (milestone "0.3.0 - Transformer Completion"
      (items
        ("Complete Ansible transformer")
        ("Complete Salt transformer")
        ("Add Terraform transformer")
        ("Add Bash script generator")))
    (milestone "0.4.0 - Routing Engine"
      (items
        ("Policy engine (allow/deny rules)")
        ("Health checker (backend availability)")
        ("Fallback routing")
        ("Routing decision telemetry")))
    (milestone "0.5.0 - CLI Demo"
      (items
        ("mix har.parse - Parse IaC file to semantic graph")
        ("mix har.route - Route graph to target format")
        ("mix har.transform - End-to-end transformation")
        ("mix har.validate - Validate routing table")))
    (milestone "0.6.0 - Distribution"
      (items
        ("libcluster integration")
        ("Distributed routing table (Horde)")
        ("Node discovery")
        ("Cross-node routing")))
    (milestone "0.7.0 - IPFS Integration"
      (items
        ("Store configs in IPFS")
        ("Content-addressed versioning")
        ("Audit trail")))
    (milestone "0.8.0 - Security"
      (items
        ("TLS certificate authentication")
        ("Security tiers implementation")
        ("Rate limiting")))
    (milestone "0.9.0 - Web Interface"
      (items
        ("Phoenix LiveView dashboard")
        ("Routing visualization")
        ("Real-time metrics")))
    (milestone "1.0.0 - MVP Release"
      (items
        ("Documentation complete")
        ("Hex.pm package")
        ("Docker/Podman deployment")
        ("Performance benchmarks"))))

  (blockers-and-issues
    (high
      ("Terraform parser not implemented" "Required for complete IaC coverage"))
    (medium
      ("Unused variable warnings" "Code cleanup needed"))
    (low
      ("Tesla deprecation warning" "ex_ipfs uses deprecated Tesla.Builder")))

  (critical-next-actions
    (immediate
      ("Create Terraform parser stub")
      ("Add JSON output format option"))
    (this-week
      ("Complete Ansible transformer")
      ("Add CLI mix tasks")
      ("Update README with usage examples"))
    (this-month
      ("Complete all parsers and transformers")
      ("Implement policy engine")
      ("Add property-based tests")))

  (session-history
    (snapshot "2026-01-10"
      (accomplishments
        ("Fixed CI/CD - all actions SHA-pinned")
        ("Fixed Elixir compilation errors")
        ("Extracted RoutingPlan/RoutingDecision structs")
        ("Fixed duplicate supervisor startup")
        ("Fixed UUID module reference")
        ("Fixed doctest in graph.ex and operation.ex")
        ("Fixed Ansible parser service type mapping (service_start, service_stop)")
        ("Created YamlFormatter module (yaml_elixir only reads, doesn't write)")
        ("Fixed all Logger.warn deprecation warnings")
        ("Tests: 59 tests + 2 doctests, all passing")))))
