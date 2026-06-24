<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
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

| proven-queueconn Type | HAR Meaning | Tag |
|------------------------|-------------|-----|
| `QueueState.Disconnected` | No connection to target | 0 |
| `QueueState.Connected` | Connected, ready to dispatch | 1 |
| `QueueState.Consuming` | Receiving events from source | 2 |
| `QueueState.Producing` | Actively dispatching events | 3 |
| `QueueState.Failed` | Connection to target lost | 4 |
| `DeliveryGuarantee.AtMostOnce` | Fire-and-forget (low priority) | 0 |
| `DeliveryGuarantee.AtLeastOnce` | Default for rpa-elysium | 1 |
| `DeliveryGuarantee.ExactlyOnce` | Idempotent targets | 2 |
| `MessageState.Pending` | Event enqueued, awaiting dispatch | 0 |
| `MessageState.Delivered` | Sent to target, awaiting ack | 1 |
| `MessageState.Acknowledged` | Target confirmed processing | 2 |
| `MessageState.Rejected` | Target rejected the event | 3 |
| `MessageState.DeadLettered` | Exceeded retry limit | 4 |
| `MessageState.Expired` | TTL elapsed | 5 |
| `QueueOp.Publish` | HAR sends event to target | 0 |
| `QueueOp.Subscribe` | HAR receives from source | 1 |
| `QueueOp.Acknowledge` | HAR acks received event | 2 |
| `QueueOp.Reject` | HAR rejects received event | 3 |
| `QueueOp.Peek` | Inspect without consuming | 4 |
| `QueueOp.Purge` | Clear target outbound queue | 5 |
| `QueueError.ConnectionLost` | Connection to target lost | 0 |
| `QueueError.QueueNotFound` | Target queue does not exist | 1 |
| `QueueError.MessageTooLarge` | Event exceeds max size | 2 |
| `QueueError.QuotaExceeded` | Queue quota exceeded | 3 |
| `QueueError.AckTimeout` | Ack not received in time | 4 |
| `QueueError.Unauthorized` | Permission denied | 5 |
| `QueueError.SerializationError` | Payload (de)serialization failed | 6 |

## Ephapax Linear Types

Supplementary linear type definitions enforce ownership semantics:

| Linear Type | Guarantee |
|-------------|-----------|
| `EventEnvelope linear` | Every incoming event is either routed or dead-lettered |
| `RouteDecision linear` | Every routing decision dispatched to exactly one target |
| `TargetConnection linear` | Every connection explicitly disconnected (no leaks) |

**Note:** When Idris2 and Ephapax conflict, Idris2 definitions are authoritative.

### Valid Router Transitions

```
Configuring ──→ Routing       (StartRouting: all targets discovered)
Routing     ──→ Shutdown      (InitiateShutdown: graceful stop)
Routing     ──→ Failed        (RoutingFault: unrecoverable error)
Configuring ──→ Failed        (ConfigFault: configuration error)
Failed      ──→ Configuring   (ResetRouter: reset and reconfigure)
```

### Zig FFI Exports

| Function | Signature | Description |
|----------|-----------|-------------|
| `har_abi_version` | `() -> u32` | ABI version (currently 1) |
| `har_router_create` | `() -> c_int` | Create router, returns slot or -1 |
| `har_router_destroy` | `(c_int) -> void` | Destroy router |
| `har_router_state` | `(c_int) -> u8` | Get MachineState tag |
| `har_router_start` | `(c_int) -> u8` | Initial->Running |
| `har_router_shutdown` | `(c_int) -> u8` | Running->Terminal |
| `har_dispatch_event` | `(c_int, u32) -> u8` | Dispatch event |
| `har_target_connect` | `(u8) -> c_int` | Connect to target |
| `har_target_disconnect` | `(c_int) -> void` | Disconnect target |
| `har_target_state` | `(c_int) -> u8` | Get QueueState tag |
| `har_last_error` | `(c_int) -> u8` | Get last error tag |
| `har_version` | `() -> [*:0]const u8` | Version string |

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
