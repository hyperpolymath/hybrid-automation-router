<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

## Required file headers (READ FIRST before creating any source file)

A pre-commit hook rejects source files missing the licence + owner header. The
exact required header (and the `(hyperpolymath)` gotcha that repeatedly bites
agents) is documented in **[`AGENT-HEADERS.md`](../AGENT-HEADERS.md)**. Run
`just install-hooks` to install the version-controlled, lenient hook. See #51.

## Machine-Readable Artefacts

The following files in `.machine_readable/` contain structured project metadata:

- `STATE.a2ml` - Current project state and progress
- `META.a2ml` - Architecture decisions and development practices
- `ECOSYSTEM.a2ml` - Position in the ecosystem and related projects
- `AGENTIC.a2ml` - AI agent interaction patterns
- `NEUROSYM.a2ml` - Neurosymbolic integration config
- `PLAYBOOK.a2ml` - Operational runbook
- `ENSAID_CONFIG.a2ml` - ENSAID configuration

---

# CLAUDE.md - AI Assistant Instructions

## Language Policy (Hyperpolymath Standard)

### ALLOWED Languages & Tools

| Language/Tool | Use Case | Notes |
|---------------|----------|-------|
| **AffineScript** | Primary application code | Affine-typed, compiles to typed-wasm or ESM |
| **Bun** | JS runtime & package management (tier 1) | Default for all new work. Runs compiled ESM/JS directly — no bundler step. Uses an npm-compatible `package.json` plus `bun.lock` — both are expected, not anti-patterns. |
| **Rust** | Performance-critical, systems, WASM | Preferred for CLI tools |
| **Tauri 2.0+** | Mobile apps (iOS/Android) | Rust backend + web UI |
| **Dioxus** | Mobile apps (native UI) | Pure Rust, React-like |
| **Gleam** | Backend services | Runs on BEAM or compiles to JS |
| **Bash/POSIX Shell** | Scripts, automation | Keep minimal |
| **JavaScript** | Only where AffineScript cannot | MCP protocol glue, Bun APIs |
| **Nickel** | Configuration language | For complex configs |
| **Guile Scheme** | State/meta files | .machine_readable/descriptiles/STATE.a2ml, .machine_readable/descriptiles/META.a2ml, .machine_readable/descriptiles/ECOSYSTEM.a2ml |
| **Julia** | Batch scripts, data processing | Per RSR |
| **OCaml** | AffineScript compiler | Language-specific |
| **Ada** | Safety-critical systems | Where required |

### BANNED - Do Not Use

| Banned | Replacement |
|--------|-------------|
| TypeScript | AffineScript |
| ReScript | AffineScript |
| Deno | Bun |
| Node.js | Bun |
| npm | Bun |
| pnpm/yarn | Bun |
| Go | Rust |
| Python | Julia/Rust/AffineScript |
| Java/Kotlin | Rust/Tauri/Dioxus |
| Swift | Tauri/Dioxus |
| React Native | Tauri/Dioxus |
| Flutter/Dart | Tauri/Dioxus |

### Mobile Development

**No exceptions for Kotlin/Swift** - use Rust-first approach:

1. **Tauri 2.0+** - Web UI (AffineScript) + Rust backend, MIT/Apache-2.0
2. **Dioxus** - Pure Rust native UI, MIT/Apache-2.0

Both are FOSS with independent governance (no Big Tech).

### Enforcement Rules

1. **No new TypeScript files** - Convert existing TS to AffineScript
2. **Use `package.json` + `bun.lock` for JS runtime deps** - Bun is npm-compatible; a manifest is REQUIRED
3. **`bun install --production --frozen-lockfile` for production deps** - resolved from `package.json` and pinned via `bun.lock`; `--frozen-lockfile` makes a lockfile mismatch a build failure rather than a silent re-resolve
4. **No Go code** - Use Rust instead
5. **No Python anywhere** - Use Julia for data/batch, Rust for systems, AffineScript for apps
6. **No Kotlin/Swift for mobile** - Use Tauri 2.0+ or Dioxus

### Package Management

- **Primary**: Guix (guix.scm)
- **Fallback**: Nix (flake.nix)
- **JS deps**: Bun (`package.json` + `bun.lock`). Declare tooling as a devDependency and run `bunx --no-install --bun <tool>` — a bare `bunx <tool>` can fetch an unpinned package and may start Node via its shebang.

### Security Requirements

- No MD5/SHA1 for security (use SHA256+)
- HTTPS only (no HTTP URLs)
- No hardcoded secrets
- SHA-pinned dependencies
- SPDX license headers on all files

---

## HAR-Specific Notes

### Architecture

Hybrid Automation Router is a pluggable routing engine that dispatches automation events from sources to targets. The core is a Rust workspace with three crates:

- **har-core** — Core types, traits (`RoutingStrategy`, `AutomationTarget`), error handling
- **har-router** — Routing engine with pluggable strategy chain
- **har-cli** — CLI for route management (list, add, remove, inspect)

### Routing Strategies

Strategies implement the `RoutingStrategy` trait and are composable:
- Score-based routing (ML weights on latency, reliability, cost)
- Load balancing (capacity-proportional distribution)
- Circuit breaking (halt on failure threshold, exponential backoff)
- Multi-strategy composition (chain strategies in order)

### proven-servers Integration

- **proven-fsm**: Router lifecycle state machine (init > ready > routing > draining > stopped)
- **proven-queueconn**: Queue-based dispatch to targets with backpressure and dead-letter handling
- ABI definitions in `src/abi/ProvenFSM.idr` and `src/abi/ProvenQueue.idr`
- Ephapax linear types in `src/abi/LinearRouting.eph` guarantee exactly-once event delivery

### rpa-elysium: First-Class Target

rpa-elysium is the primary consumer of routed events. The `AutomationTarget` trait is designed around its bot framework API. Dedicated monitoring panels live in `panels/rpa-elysium/`.

### PanLL Panels

Dashboard panels in `panels/` — always call them "panels", never "panes":
- `panels/har-dashboard/` — Router health, dispatch latency, target status
- `panels/rpa-elysium/` — rpa-elysium-specific monitoring

---

## Build Commands

```bash
# Full workspace check
cargo check --workspace

# Run all tests
cargo test --workspace

# Lint (treat warnings as errors)
cargo clippy --workspace -- -D warnings

# Format check
cargo fmt --check

# Task runner (all-in-one)
just check

# Pre-commit (if panic-attack available)
panic-attack assail
```
