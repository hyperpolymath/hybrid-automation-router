<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-03-16 -->

# Hybrid Automation Router — Project Topology

## System Architecture

```
                        ┌─────────────────────────────────────────┐
                        │            EVENT SOURCES                │
                        │   (Cron, Webhooks, File Watchers, CLI)  │
                        └───────────────────┬─────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │          ROUTER ENGINE (RUST)           │
                        │  ┌───────────┐  ┌───────────────────┐  │
                        │  │ Strategy  │  │  Strategy Chain    │  │
                        │  │ Scoring   │──│  (compose, select) │  │
                        │  └─────┬─────┘  └────────┬──────────┘  │
                        │        │    Circuit       │             │
                        │        │    Breaker ──────┘             │
                        │  ┌─────┴─────────────────────────────┐  │
                        │  │  proven-fsm Lifecycle Manager     │  │
                        │  │  (init → ready → routing → stop)  │  │
                        │  └───────────────────────────────────┘  │
                        └──────────┬──────────────────────────────┘
                                   │
                                   ▼
                        ┌─────────────────────────────────────────┐
                        │       proven-queueconn DISPATCH         │
                        │  (Backpressure, Retry, Dead-Letter)     │
                        └──────┬─────────┬─────────┬──────────────┘
                               │         │         │
                    ┌──────────┘         │         └──────────┐
                    ▼                    ▼                     ▼
          ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
          │  rpa-elysium     │ │  API Integration │ │  Document / Desktop│
          │  (PRIMARY)       │ │  Target          │ │  Targets          │
          │  Web Automation  │ │  REST/GraphQL    │ │  PDF, Excel, etc. │
          └──────────────────┘ └──────────────────┘ └──────────────────┘

                        ┌─────────────────────────────────────────┐
                        │          ABI / FFI LAYER                │
                        │  Idris2 ABI Defs     Zig C-FFI Impl    │
                        │  src/abi/            ffi/zig/           │
                        │  Ephapax Linear Types (exactly-once)    │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │         PanLL MONITORING PANELS         │
                        │  panels/har-dashboard   Route health    │
                        │  panels/rpa-elysium     Target status   │
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │          REPO INFRASTRUCTURE            │
                        │  Justfile Automation  .machine_readable/│
                        │  Multi-Forge Hub      0-AI-MANIFEST.a2ml│
                        └─────────────────────────────────────────┘
```

## Completion Dashboard

```
COMPONENT                          STATUS              NOTES
─────────────────────────────────  ──────────────────  ─────────────────────────────────
RUST WORKSPACE
  har-core                          ██████████ 100%    Types, traits, error handling
  har-router                        █████████░  90%    Routing engine, strategy chain
  har-cli                           ████████░░  80%    CLI, route management

ABI / FFI
  Idris2 ABI definitions           ██████░░░░  60%    ProvenFSM, ProvenQueue
  Zig FFI implementation           ██████░░░░  60%    Build scaffold + bindings
  Ephapax linear types             ██████░░░░  60%    LinearRouting.eph

ECOSYSTEM INTEGRATION
  proven-servers bindings           ██████░░░░  60%    FSM lifecycle, queueconn dispatch
  PanLL panels                      ██████████ 100%    har-dashboard + rpa-elysium panels
  Gleam backend service             ██░░░░░░░░  20%    Scaffold only

PLATFORM (PLANNED)
  Advanced Routing (Phase 2)        █░░░░░░░░░  10%    ML scoring, circuit breakers
  Observability (Phase 3)           █░░░░░░░░░  10%    Metrics, tracing, alerting
  Target Ecosystem (Phase 4)        █░░░░░░░░░  10%    Web, API, doc, desktop targets
  Enterprise (Phase 5)              ░░░░░░░░░░   0%    Multi-tenancy, SSO, SLA

INFRASTRUCTURE
  CI/CD Pipelines                   ██████████ 100%    Forge sync stable
  Governance & Standards            ██████████ 100%    RSR 2026 compliant
  .machine_readable/                ██████████ 100%    STATE tracking active

REPO INFRASTRUCTURE
  Justfile Automation               ██████████ 100%    Standard build tasks
  0-AI-MANIFEST.a2ml                ██████████ 100%    AI entry point verified
  Language Policy                   ██████████ 100%    Hyperpolymath Standard verified

─────────────────────────────────────────────────────────────────────────────
OVERALL:                            ██░░░░░░░░  ~25%   Phase 1 In Progress
```

## Key Dependencies

```
RSR Standards ───► Infrastructure ───► Core Framework ───► Targets
     │                 │                   │                 │
     ▼                 ▼                   ▼                 ▼
Language Policy ► CI Workflows ─────► proven-servers ──► rpa-elysium
                                          │
                                          ▼
                                     PanLL Panels
```

## Update Protocol

This file is maintained by both humans and AI agents. When updating:

1. **After completing a component**: Change its bar and percentage
2. **After adding a component**: Add a new row in the appropriate section
3. **After architectural changes**: Update the ASCII diagram
4. **Date**: Update the `Last updated` comment at the top of this file

Progress bars use: `█` (filled) and `░` (empty), 10 characters wide.
Percentages: 0%, 10%, 20%, ... 100% (in 10% increments).
