;; SPDX-License-Identifier: MPL-2.0
;; STATE.scm - Project state for HAR (Hybrid Automation Router)

(state
  (metadata
    (version "1.0.0-rc1")
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
      ("jason" "JSON encoding/decoding")
      ("libcluster" "Distributed clustering")
      ("horde" "Distributed process registry")))

  (current-position
    (phase "beta")
    (overall-completion 85)
    (components
      (semantic-graph 90)
      (ansible-parser 90)
      (salt-parser 70)
      (terraform-parser 90)
      (ansible-transformer 80)
      (salt-transformer 70)
      (terraform-transformer 90)
      (routing-engine 85)
      (routing-table 90)
      (health-checker 80)
      (policy-engine 80)
      (cli-tasks 90)
      (ipfs-integration 10)
      (security-manager 20)
      (web-endpoint 10)
      (telemetry 70)
      (ci-cd 100))
    (working-features
      ("Elixir project compiles" "mix compile succeeds with no warnings")
      ("Semantic Graph IR" "Operations, Dependencies, Graph structures with full type specs")
      ("Ansible YAML parsing" "Parses playbooks to semantic graph with correct operation types")
      ("Salt SLS parsing" "Parses states to semantic graph")
      ("Terraform parsing" "Parses both HCL and JSON formats to semantic graph")
      ("Terraform JSON output" "Generates valid Terraform JSON with AWS/GCP/Azure support")
      ("Ansible YAML output" "Generates Ansible playbooks from semantic graph")
      ("YAML output" "YamlFormatter for serializing configs")
      ("Routing table" "GenServer with YAML-based patterns")
      ("Health checker" "Backend health monitoring with multiple check types")
      ("Policy engine" "Allow/deny rules, environment constraints, device filtering")
      ("Basic routing logic" "Pattern matching to backends with health/policy integration")
      ("CLI mix tasks" "mix har.parse, har.transform, har.convert")
      ("Telemetry infrastructure" "Metrics and logging")
      ("CI/CD workflows" "All GitHub Actions SHA-pinned")
      ("Test suite" "108 tests passing (106 unit + 2 doctests)")))

  (route-to-mvp
    (milestone "0.2.0 - Parser Completion" (status complete)
      (items
        ("Add Terraform HCL parser" done)
        ("Add Terraform JSON parser" done)
        ("Add JSON output format" done)))
    (milestone "0.3.0 - Transformer Completion" (status complete)
      (items
        ("Complete Ansible transformer" done)
        ("Complete Salt transformer" partial)
        ("Add Terraform transformer" done)))
    (milestone "0.4.0 - Routing Engine" (status complete)
      (items
        ("Policy engine (allow/deny rules)" done)
        ("Health checker (backend availability)" done)
        ("Fallback routing" partial)
        ("Routing decision telemetry" done)))
    (milestone "0.5.0 - CLI Demo" (status complete)
      (items
        ("mix har.parse - Parse IaC file to semantic graph" done)
        ("mix har.convert - End-to-end transformation" done)
        ("mix har.transform - Transform graph to target format" done)))
    (milestone "0.6.0 - Distribution" (status pending)
      (items
        ("libcluster integration")
        ("Distributed routing table (Horde)")
        ("Node discovery")
        ("Cross-node routing")))
    (milestone "0.7.0 - IPFS Integration" (status pending)
      (items
        ("Store configs in IPFS")
        ("Content-addressed versioning")
        ("Audit trail")))
    (milestone "0.8.0 - Security" (status pending)
      (items
        ("TLS certificate authentication")
        ("Security tiers implementation")
        ("Rate limiting")))
    (milestone "0.9.0 - Web Interface" (status pending)
      (items
        ("Phoenix LiveView dashboard")
        ("Routing visualization")
        ("Real-time metrics")))
    (milestone "1.0.0 - MVP Release" (status in-progress)
      (items
        ("Documentation complete" partial)
        ("Hex.pm package" pending)
        ("Docker/Podman deployment" pending)
        ("Performance benchmarks" pending))))

  (blockers-and-issues
    (resolved
      ("Terraform parser not implemented" "Now fully implemented with HCL/JSON support")
      ("Unused variable warnings" "All 10 warnings fixed"))
    (low
      ("Tesla deprecation warning" "ex_ipfs uses deprecated Tesla.Builder")))

  (critical-next-actions
    (immediate
      ("Finalize documentation")
      ("Publish to Hex.pm"))
    (this-week
      ("Add Docker/Podman deployment example")
      ("Performance benchmarks")
      ("Release 1.0.0"))
    (this-month
      ("Implement distributed routing (libcluster)")
      ("Add IPFS integration")
      ("Build web dashboard")))

  (session-history
    (snapshot "2026-01-10-mvp"
      (accomplishments
        ("Implemented Terraform HCL parser with full resource type mapping")
        ("Implemented Terraform transformer with AWS/GCP/Azure support")
        ("Added 47 new tests for Terraform parser/transformer")
        ("Created CLI tasks: har.parse, har.transform, har.convert")
        ("Implemented HealthChecker GenServer with multiple check types")
        ("Implemented PolicyEngine with allow/deny/prefer rules")
        ("Integrated health checker and policy engine into Router")
        ("Fixed all 10 unused variable warnings")
        ("Updated supervisor to include new control plane components")
        ("Created Terraform example file (examples/terraform/webserver.tf)")
        ("All tests passing: 108 tests (106 unit + 2 doctests)")
        ("Overall completion: 40% -> 85%")))
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
