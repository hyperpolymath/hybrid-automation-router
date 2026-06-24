<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# PROOF-NEEDS.md — hybrid-automation-router

Tracker for proof obligations against the routing-core invariants
(issue #49). Use the standard `Status` column vocabulary:

- `STUB` — type stated, body is `?hole`.
- `WIP` — partial proof, some holes remain.
- `CLOSED` — proof complete, machine-checked.
- `WONTFIX` — superseded or out of scope.

## Idris2 ABI obligations (`src/abi/RoutingInvariants.idr`)

| ID | Statement | Status | Notes |
|----|-----------|--------|-------|
| RI-1 | `noEventLoss` — at quiescence every accepted event is Delivered or DeadLettered | STUB | Holes: `noEventLoss_rhs`. Depends on a faithful model of the dispatcher loop in Idris2; today only the *type* is checked. |
| RI-2 | `noDuplicateDispatch` — ExactlyOnce events deliver at most once | STUB | Holes: `noDuplicateDispatch_rhs`. Needs DeliveryGuarantee-conditioned variant for AtLeastOnce / AtMostOnce. |
| RI-3 | `deterministicSelection` — same snapshot ⇒ same target | **CLOSED** | Trivial by `Refl`; the actual content is the Rust-side property test (see RR-3 below) that the snapshot type *cannot* depend on HashMap iteration order. |

## Rust runtime obligations (property tests)

| ID | Statement | Status | Notes |
|----|-----------|--------|-------|
| RR-1 | `Router::route` is total: never panics, never returns an unregistered `target_id` | STUB | Filed under PR3/PR4 follow-up. proptest harness owed. |
| RR-2 | Dispatcher under arbitrary failure schedule either delivers exactly once or dead-letters with `attempts == max_attempts` | STUB | Filed under PR4. Requires injectable failure schedule on the transport. |
| RR-3 | Routing decision is independent of HashMap iteration order | STUB | Easy first proptest — feed shuffled targets, check decision is invariant. |

## Echo-types audit (per 2026-06-01 owner directive)

Per the estate-wide "Proofs MUST check + cross-doc echo-types" directive,
every proof obligation in this repo must first audit `hyperpolymath/echo-types`.

| Obligation | Echo-types applicability | Decision |
|------------|--------------------------|----------|
| RI-1 (noEventLoss) | L1 (region) — accepted set / in-flight set / resolved set are disjoint partitions of the event population. L3 (echo) — the dispatch trace IS an echo trace if we want bisimilarity between the Idris2 model and the Rust runtime. | **L1: not directly relevant** (no shared echo region with another estate library). **L3: RECORD-AS-FUTURE-WORK** — once the Rust dispatcher exposes a trace adapter, the echo equivalence to the Idris2 model becomes a useful theorem. Not on the critical path today. |
| RI-2 (noDuplicateDispatch) | L3 (echo) — duplicates in the dispatch trace are a coalgebraic equality failure. | **L3: RECORD-AS-NOT-RELEVANT** today — there is no estate-wide echo-types codec for `DispatchCount` and inventing one for this single use-site would be scope-creep. Revisit if a second consumer appears (e.g. rpa-elysium-side replay verification). |
| RI-3 (deterministicSelection) | L1 only (no echo involved). | **Not relevant.** Pure determinism, no co-algebraic structure. |
| RR-1 (route is total) | L1. | Not relevant. |
| RR-2 (deliver-or-DLQ) | L3 (echo) — the dispatcher trace and the DLQ form a sum that is closed under failure schedules. | **L3: RECORD-AS-FUTURE-WORK** (same shape as RI-1). |
| RR-3 (no iteration-order dep) | L1. | Not relevant. |

Conclusion: no upstream `hyperpolymath/echo-types` extension is required to
unblock the current proof programme. Two obligations (RI-1, RR-2) would
benefit from echo-types integration *once* a second consumer appears; both
are recorded for future cross-doc.

## Cross-references

- Issue [#49](https://github.com/hyperpolymath/hybrid-automation-router/issues/49) — self-audit roll-up.
- `src/abi/LinearRouting.eph` — prose statement of the same invariants.
- `src/abi/RoutingInvariants.idr` — type-level statement.
- `TEST-NEEDS.md` — runtime test coverage tracker (CRG grade).
