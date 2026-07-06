<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2025-2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# Hybrid Automation Router (HAR)

**Intelligent event routing for automation targets**

[![RSR Certified](https://img.shields.io/badge/RSR-Certified-gold)](https://github.com/hyperpolymath/rhodium-standard-repositories)
![Status](https://img.shields.io/badge/Status-Phase%202%20(interlingua)-yellow)

<div id="toc">

</div>

# Overview

The Hybrid Automation Router (HAR) is an intelligent routing layer that
receives automation events from multiple sources (filesystem watchers,
webhooks, queues, schedules) and routes them to the best automation target
based on capabilities, tags, priorities, and configurable strategies.

The v0.2.0 workspace is a Rust workspace of **7 crates** covering core routing,
configuration management, event dispatch with retry and dead-letter handling,
health checking with degradation tracking, and metrics collection with
snapshots. The routing engine compiles and its tests pass; production
deployment against live targets is not yet validated (Phase 1 is near complete).

HAR is designed for **tight integration** with
[RPA Elysium](https://github.com/hyperpolymath/rpa-elysium) while remaining
fully independent — either can be used standalone.

> **Direction (Phase 2).** HAR is being extended into a declarative/imperative
> **automation interlingua** — a tool-neutral substrate (carried on A2ML) that
> lets heterogeneous automation estates (Puppet, Salt, Terraform, Ansible) hand
> off and resume across each other, with HAR as the seam. See
> [`docs/decisions/0002-automation-interlingua-declarative-imperative.adoc`](docs/decisions/0002-automation-interlingua-declarative-imperative.adoc).

# Architecture

                        ┌──────────────────────────────────────┐
                        │        EVENT SOURCES                  │
                        │  Filesystem │ Webhook │ Queue │ Cron  │
                        └──────────┬───────────────────────────┘
                                   │
                                   ▼
                        ┌──────────────────────────────────────┐
                        │     HYBRID AUTOMATION ROUTER          │
                        │  ┌────────────┐ ┌─────────────────┐  │
                        │  │  Context   │ │  Route Engine    │  │
                        │  │  Analyzer  │ │  (strategies)    │  │
                        │  └─────┬──────┘ └────────┬────────┘  │
                        │        │     Shared ABI    │          │
                        │  ┌─────┴──────────────────┴────────┐ │
                        │  │  proven-fsm │ proven-queueconn  │ │
                        │  └─────────────────────────────────┘ │
                        └──────────┬───────────────┬───────────┘
                                   │               │
                        ┌──────────▼──────┐ ┌──────▼───────────┐
                        │  rpa-elysium    │ │  Other targets    │
                        │  (filesystem)   │ │  (web, API, etc.) │
                        └─────────────────┘ └──────────────────┘

The Rust routing/dispatch core is implemented and tested. The **shared ABI**
band (proven-fsm / proven-queueconn) and the Gleam backend are **design
scaffold** — see *Status* below.

# RPA Elysium Integration

HAR and RPA Elysium are designed to share:

- **proven-fsm types** — the same state-machine vocabulary for workflow
  transitions *(planned: ABI defined, not yet wired into the Rust core)*.
- **proven-queueconn** — HAR publishes tasks, rpa-elysium subscribes
  *(planned: the queueconn runtime is not yet implemented)*.
- **Common event schema** — Idris2 ABI definitions in `src/abi/` *(scaffold —
  type stubs; see Status)*.

## Using Both Together

```bash
# Start rpa-elysium in the background (subscribes to queue)
rpa-fs run workflow.json &

# Route events through HAR
har route filesystem --target rpa-elysium
```

# Technology Stack

| Layer | Technology | State |
|----|----|----|
| **Core engine** | Rust — 7 crates (har-core, har-config, har-dispatch, har-health, har-metrics, har-router, har-cli) | ✅ implemented + tested |
| **ABI** | Idris2 (`src/abi/*.idr`) — router lifecycle + queue types | ⚠ scaffold (type stubs; not yet compiled/proven or wired to Rust) |
| **Linear types** | Ephapax (`src/abi/LinearRouting.eph`) — exactly-once delivery | ⚠ spec only |
| **FFI** | Zig (`ffi/zig/`) — C-compatible boundary | ⚠ scaffold (not invoked from Rust) |
| **Backend** | Gleam (BEAM — event bus, persistence) | ☐ planned (not started) |
| **Config** | Nickel (typed configuration) | partial |
| **Build** | Guix (`guix.scm`, reproducible) | ✅ |

# Quick Start

```bash
# Build
cargo build --workspace

# Run tests
cargo test --workspace

# Show registered targets
har targets

# Route a filesystem event
har route filesystem

# Route with a target hint
har route web --target web-auto
```

# Crate Structure

| Crate | Purpose |
|----|----|
| `har-core` | Core types: events, targets, routes, strategies |
| `har-config` | Configuration loading and validation (JSON, file-based) |
| `har-dispatch` | Event dispatch to targets with retry and dead-letter queues |
| `har-health` | Health checking for targets with degradation tracking |
| `har-metrics` | Metrics collection for routing decisions with snapshots |
| `har-router` | Routing engine — strategy-dispatched target selection |
| `har-cli` | Command-line interface for route management |

# Routing Strategies

All seven strategies are implemented; the final target selection is dispatched
on the router's configured strategy, and selection is **deterministic** (it
never depends on hash-map iteration order).

| Strategy | Description |
|---------------------|---------------------------------------------|
| **Direct** | Target hint bypasses all rules |
| **CapabilityMatch** | Match event category to target capabilities (highest weight; ties broken by id) |
| **TagMatch** | Tag-based routing rules |
| **RoundRobin** | Rotate across matching targets |
| **WeightedRandom** | Weight-proportional, deterministic per event (seeded from the event id) |
| **LeastLoaded** | Send to the least-busy target |
| **Failover** | Highest-weight primary with an ordered fallback chain |

# Status

- **Phase 0 (foundation):** ✅ complete.
- **Phase 1 (core framework):** ⚙ near complete — the 7 Rust crates are
  implemented and tested; remaining: proven-queueconn runtime + Gleam backend.
- **Phase 2 (automation interlingua):** ◆ the current north star (see
  *Direction* above and `ROADMAP.adoc`).
- **Scaffold, not yet real:** the Idris2 ABI (`src/abi/`) and Ephapax linear
  types are design stubs — they do not yet compile as a package or wire into the
  Rust runtime; `panels/` and a Gleam `services/` backend referenced in earlier
  drafts do not exist yet. Proof obligations are tracked in `PROOF-NEEDS.md`.

See [`ROADMAP.adoc`](ROADMAP.adoc) for the full phased plan.

# License

Code: MPL-2.0. Documentation: CC-BY-SA-4.0. © 2025–2026 Jonathan D.A. Jewell.

# Author

**Jonathan D.A. Jewell** — GitHub: [@hyperpolymath](https://github.com/hyperpolymath)
