<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Contributing to hybrid-automation-router

Thank you for your interest in contributing to the Hybrid Automation Router (HAR). This document explains how to set up your development environment, contribute code, and follow project conventions.

## Getting Started

### Prerequisites

- Rust (stable toolchain via asdf or rustup)
- `just` task runner
- Idris2 (for ABI definitions)
- Zig (for FFI implementation)
- Gleam (for backend services)

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/hyperpolymath/hybrid-automation-router.git
cd hybrid-automation-router

# Using Nix (recommended for reproducibility)
nix develop

# Or using toolbox/distrobox
toolbox create hybrid-automation-router-dev
toolbox enter hybrid-automation-router-dev
# Install dependencies manually

# Verify setup
just check   # or: cargo check --workspace
just test    # Run test suite
```

### Repository Structure
```
hybrid-automation-router/
├── crates/              # Rust workspace crates
│   ├── har-core/        # Core types, traits, error handling
│   ├── har-router/      # Routing engine with pluggable strategies
│   └── har-cli/         # CLI for route management
├── src/abi/             # Idris2 ABI definitions + Ephapax linear types
├── ffi/zig/             # Zig FFI implementation
├── panels/              # PanLL monitoring panels
│   ├── har-dashboard/   # Router health dashboard
│   └── rpa-elysium/     # rpa-elysium integration panel
├── services/            # Gleam backend services
├── docs/                # Documentation (Perimeter 3)
│   ├── architecture/    # ADRs, specs (Perimeter 2)
│   └── proposals/       # RFCs (Perimeter 3)
├── examples/            # Examples (Perimeter 3)
├── verification/        # Formal verification artefacts
├── .machine_readable/   # ALL machine-readable content (Perimeter 1)
│   ├── *.a2ml           # State files (STATE, META, ECOSYSTEM, etc.)
│   ├── bot_directives/  # Bot configs
│   └── contractiles/    # Policy contracts (k9, dust, lust, must, trust)
├── .well-known/         # Protocol files (Perimeter 1-3)
├── .github/             # GitHub config (Perimeter 1)
│   ├── ISSUE_TEMPLATE/
│   └── workflows/
├── CHANGELOG.md
├── CONTRIBUTING.adoc    # AsciiDoc overview (points here)
├── CONTRIBUTING.md      # This file (detailed contribution guide)
├── LICENSE
├── README.adoc
├── ROADMAP.adoc
├── SECURITY.md
├── TOPOLOGY.md
├── flake.nix            # Nix flake — fallback (Perimeter 1)
├── guix.scm             # Guix package — primary (Perimeter 1)
├── Justfile             # Task runner (Perimeter 1)
└── Cargo.toml           # Rust workspace root
```

---

## How to Contribute

### Reporting Bugs

**Before reporting**:
1. Search existing issues
2. Check if it's already fixed in `main`
3. Determine which perimeter the bug affects

**When reporting**:

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) and include:

- Clear, descriptive title
- Environment details (OS, versions, toolchain)
- Steps to reproduce
- Expected vs actual behaviour
- Logs, screenshots, or minimal reproduction

### Suggesting Features

**Before suggesting**:
1. Check the [roadmap](ROADMAP.adoc) if available
2. Search existing issues and discussions
3. Consider which perimeter the feature belongs to

**When suggesting**:

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md) and include:

- Problem statement (what pain point does this solve?)
- Proposed solution
- Alternatives considered
- Which perimeter this affects

### Your First Contribution

Look for issues labelled:

- [`good first issue`](https://github.com/hyperpolymath/hybrid-automation-router/labels/good%20first%20issue) — Simple Perimeter 3 tasks
- [`help wanted`](https://github.com/hyperpolymath/hybrid-automation-router/labels/help%20wanted) — Community help needed
- [`documentation`](https://github.com/hyperpolymath/hybrid-automation-router/labels/documentation) — Docs improvements
- [`perimeter-3`](https://github.com/hyperpolymath/hybrid-automation-router/labels/perimeter-3) — Community sandbox scope

---

## Development Workflow

### Branch Naming
```
docs/short-description       # Documentation (P3)
test/what-added              # Test additions (P3)
feat/short-description       # New features (P2)
fix/issue-number-description # Bug fixes (P2)
refactor/what-changed        # Code improvements (P2)
security/what-fixed          # Security fixes (P1-2)
```

### Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):
```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `ci`, `chore`

Scopes: `har-core`, `har-router`, `har-cli`, `abi`, `ffi`, `panels`, `services`

### Build and Test

```bash
# Full workspace check
cargo check --workspace

# Run all tests
cargo test --workspace

# Lint
cargo clippy --workspace -- -D warnings

# Format check
cargo fmt --check

# Full quality check (recommended before committing)
just check
```

---

## HAR-Specific Contribution Notes

### Routing Strategies

New routing strategies should:
1. Implement the `RoutingStrategy` trait in `har-router`
2. Be composable with other strategies via the strategy chain
3. Include unit tests covering edge cases (empty target list, all targets down, etc.)
4. Document the scoring/selection algorithm in the strategy's module doc comment

### rpa-elysium Integration Testing

When modifying code that affects event dispatch to rpa-elysium:
1. Ensure the `AutomationTarget` trait contract is preserved
2. Test with the `panels/rpa-elysium` panel to verify monitoring data flows
3. Verify that Ephapax linear type guarantees (exactly-once delivery) are maintained
4. Run integration tests against a mock rpa-elysium target

### proven-servers Integration

Changes to FSM lifecycle or queue dispatch must:
1. Preserve the state machine invariants defined in `src/abi/ProvenFSM.idr`
2. Ensure queueconn dispatch matches the ABI contract in `src/abi/ProvenQueue.idr`
3. Not introduce `believe_me`, `assert_total`, or other unsound escape hatches

### PanLL Panels

Panel contributions should:
1. Live in `panels/` under the appropriate subdirectory
2. Use PanLL's data source protocol for live metrics
3. Never use the word "panes" — always "panels"

---

## Code Quality Standards

- All files must have SPDX license headers
- All public functions must have doc comments
- No `unsafe` Rust without a `// SAFETY:` comment
- No banned languages (TypeScript, Python, Go, Node.js, npm, Bun)
- Use `cargo clippy` with `-D warnings`
- No hardcoded secrets or credentials

---

## License

By contributing, you agree that your contributions will be licensed under PMPL-1.0-or-later.
