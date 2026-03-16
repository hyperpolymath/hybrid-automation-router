<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# ABI/FFI Architecture — Hybrid Automation Router

## Overview

HAR uses the **hyperpolymath universal ABI/FFI standard** with proven-servers integration:

| Layer | Language | Purpose | Location |
|-------|----------|---------|----------|
| **ABI** | Idris2 | Interface definitions with formal proofs | `src/abi/` |
| **FFI** | Zig | C-compatible implementation | `ffi/zig/` |
| **Linear** | Ephapax | Ownership semantics (supplementary) | `src/abi/*.eph` |
| **Headers** | C (generated) | Bridge between ABI and FFI | `generated/abi/` |

## proven-servers Integration

HAR consumes types from two proven-servers modules:

### proven-fsm (Finite State Machine)

Maps router lifecycle to formally verified state machine:

| proven-fsm Type | HAR Meaning | Tag |
|-----------------|-------------|-----|
| `MachineState.Initial` | Router configuring | 0 |
| `MachineState.Running` | Router active, routing events | 1 |
| `MachineState.Terminal` | Router shut down gracefully | 2 |
| `MachineState.Faulted` | Router encountered fatal error | 3 |
| `TransitionResult.Accepted` | Transition succeeded | 0 |
| `TransitionResult.Rejected` | Invalid transition | 1 |
| `TransitionResult.Deferred` | Valid but deferred | 2 |
| `EventDisposition.Consumed` | Event routed to target | 0 |
| `EventDisposition.Ignored` | No matching target | 1 |
| `EventDisposition.Queued` | Deferred for later | 2 |
| `EventDisposition.Dropped` | Dead-lettered / overflow | 3 |

### proven-queueconn (Queue Connector)

Manages connections to downstream automation targets (rpa-elysium, etc.):

| proven-queueconn Type | HAR Meaning |
|------------------------|-------------|
| `QueueState.Disconnected` | No connection to target |
| `QueueState.Connected` | Connected, ready to dispatch |
| `QueueState.Producing` | Actively dispatching events |
| `QueueState.Failed` | Connection to target lost |
| `DeliveryGuarantee.AtLeastOnce` | Default for rpa-elysium |

## Ephapax Linear Types

Supplementary linear type definitions enforce ownership semantics:

| Linear Type | Guarantee |
|-------------|-----------|
| `EventEnvelope linear` | Every incoming event is either routed or dead-lettered |
| `RouteDecision linear` | Every routing decision dispatched to exactly one target |
| `TargetConnection linear` | Every connection explicitly disconnected (no leaks) |

**Note:** When Idris2 and Ephapax conflict, Idris2 definitions are authoritative.

## Directory Structure

```
src/abi/
  ProvenFSM.idr       — FSM types for router lifecycle
  ProvenQueue.idr      — Queue types for target dispatch
  LinearRouting.eph    — Ephapax linear ownership types

ffi/zig/
  build.zig            — Zig build config (shared + static lib)
  src/main.zig         — C-compatible FFI stubs

generated/abi/         — Auto-generated C headers (not yet implemented)
```

## Building

```bash
# Rust workspace (does not depend on FFI yet)
cargo build --workspace

# Zig FFI library
cd ffi/zig && zig build

# Zig FFI tests
cd ffi/zig && zig build test
```

## Shared Surface with rpa-elysium

Both repos consume the same proven-servers ABI types with identical tag values.
Events flow: HAR (Producing) → Queue → rpa-elysium (Consuming).
