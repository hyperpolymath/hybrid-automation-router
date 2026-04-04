# TEST-NEEDS.md — hybrid-automation-router

## CRG Grade: C — ACHIEVED 2026-04-04

## Current Test State

| Category | Count | Notes |
|----------|-------|-------|
| Smoke tests | 3 | crates/har-core/tests/smoke_test.rs — crate links, error types, Result alias |

## What's Covered

- [x] har-core compiles and links (`smoke_test.rs`)
- [x] Error type implements Debug
- [x] Result type alias resolves

## Still Missing (for CRG B+)

- [ ] Unit tests for routing dispatch logic
- [ ] Integration tests for har-dispatch + har-router
- [ ] Property tests for event routing determinism
- [ ] CLI smoke tests

## Run Tests

```bash
cargo test -p har-core
```
