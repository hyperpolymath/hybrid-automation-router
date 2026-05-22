-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- ProvenFSM: proven-fsm types adapted for the Hybrid Automation Router.
--
-- This module re-exports the proven-fsm state machine types with HAR-specific
-- semantics.  The core proven-fsm library defines a generic finite state
-- machine; here we map those types to the router lifecycle:
--
--   MachineState  ->  RouterState
--   ──────────────────────────────
--   Initial       ->  Configuring   (router loading config, discovering targets)
--   Running       ->  Routing       (actively dispatching events to targets)
--   Terminal      ->  Shutdown      (graceful shutdown, draining in-flight events)
--   Faulted       ->  Failed        (unrecoverable error, requires reset)
--
--   TransitionResult  ->  used for router lifecycle transitions
--   EventDisposition  ->  used when events arrive at the router
--   ──────────────────────────────────────────────
--   Consumed  ->  event was routed to a matching target
--   Ignored   ->  no target matched (dead-letter candidate)
--   Queued    ->  event deferred (target temporarily unavailable)
--   Dropped   ->  event dropped (queue overflow or circuit-breaker open)
--
-- Tag values MUST match proven-servers exactly:
--   TransitionResult: Accepted=0, Rejected=1, Deferred=2
--   ValidationError:  InvalidTransition=0, PreconditionFailed=1,
--                     PostconditionFailed=2, GuardFailed=3
--   MachineState:     Initial=0, Running=1, Terminal=2, Faulted=3
--   EventDisposition: Consumed=0, Ignored=1, Queued=2, Dropped=3

module HAR.ABI.ProvenFSM

import Data.Bits

%default total

---------------------------------------------------------------------------
-- RouterState — the lifecycle state of the Hybrid Automation Router.
-- Maps 1:1 to proven-fsm MachineState with HAR-specific names.
---------------------------------------------------------------------------

||| The lifecycle state of the Hybrid Automation Router.
||| Tag values match proven-fsm MachineState exactly.
public export
data RouterState : Type where
  ||| Router is loading configuration and discovering automation targets.
  ||| Tag value: 0 (matches proven-fsm Initial)
  Configuring : RouterState
  ||| Router is actively dispatching events to matched targets.
  ||| Tag value: 1 (matches proven-fsm Running)
  Routing     : RouterState
  ||| Router is performing graceful shutdown, draining in-flight events.
  ||| Tag value: 2 (matches proven-fsm Terminal)
  Shutdown    : RouterState
  ||| Router has encountered an unrecoverable error and requires reset.
  ||| Tag value: 3 (matches proven-fsm Faulted)
  Failed      : RouterState

public export
Show RouterState where
  show Configuring = "Configuring"
  show Routing     = "Routing"
  show Shutdown    = "Shutdown"
  show Failed      = "Failed"

||| Convert RouterState to C-compatible tag value.
||| Tag assignments match proven-fsm MachineState exactly.
public export
routerStateToTag : RouterState -> Bits8
routerStateToTag Configuring = 0  -- Initial
routerStateToTag Routing     = 1  -- Running
routerStateToTag Shutdown    = 2  -- Terminal
routerStateToTag Failed      = 3  -- Faulted

||| Convert C tag value back to RouterState.
public export
tagToRouterState : Bits8 -> Maybe RouterState
tagToRouterState 0 = Just Configuring
tagToRouterState 1 = Just Routing
tagToRouterState 2 = Just Shutdown
tagToRouterState 3 = Just Failed
tagToRouterState _ = Nothing

---------------------------------------------------------------------------
-- TransitionResult — outcome of attempting a router state transition.
-- Re-exported from proven-fsm without renaming.
---------------------------------------------------------------------------

||| The result of attempting a router lifecycle transition.
||| Tag values: Accepted=0, Rejected=1, Deferred=2
public export
data TransitionResult : Type where
  ||| The transition was accepted and the router state has changed.
  Accepted : TransitionResult
  ||| The transition was rejected (invalid from current state).
  Rejected : TransitionResult
  ||| The transition is valid but deferred (e.g., waiting for in-flight events to drain).
  Deferred : TransitionResult

public export
Show TransitionResult where
  show Accepted = "Accepted"
  show Rejected = "Rejected"
  show Deferred = "Deferred"

||| Convert TransitionResult to C-compatible tag value.
public export
transitionResultToTag : TransitionResult -> Bits8
transitionResultToTag Accepted = 0
transitionResultToTag Rejected = 1
transitionResultToTag Deferred = 2

||| Convert C tag value back to TransitionResult.
public export
tagToTransitionResult : Bits8 -> Maybe TransitionResult
tagToTransitionResult 0 = Just Accepted
tagToTransitionResult 1 = Just Rejected
tagToTransitionResult 2 = Just Deferred
tagToTransitionResult _ = Nothing

---------------------------------------------------------------------------
-- ValidationError — reasons a router transition was rejected.
-- Re-exported from proven-fsm without renaming.
---------------------------------------------------------------------------

||| Reasons a router lifecycle transition can fail validation.
||| Tag values: InvalidTransition=0, PreconditionFailed=1,
|||             PostconditionFailed=2, GuardFailed=3
public export
data ValidationError : Type where
  ||| The transition is not valid from the current router state.
  InvalidTransition   : ValidationError
  ||| A precondition guard was not satisfied (e.g., no targets configured).
  PreconditionFailed  : ValidationError
  ||| A postcondition check was not satisfied (e.g., health check failed).
  PostconditionFailed : ValidationError
  ||| A guard function returned false (e.g., in-flight events still draining).
  GuardFailed         : ValidationError

public export
Show ValidationError where
  show InvalidTransition   = "InvalidTransition"
  show PreconditionFailed  = "PreconditionFailed"
  show PostconditionFailed = "PostconditionFailed"
  show GuardFailed         = "GuardFailed"

||| Convert ValidationError to C-compatible tag value.
public export
validationErrorToTag : ValidationError -> Bits8
validationErrorToTag InvalidTransition   = 0
validationErrorToTag PreconditionFailed  = 1
validationErrorToTag PostconditionFailed = 2
validationErrorToTag GuardFailed         = 3

---------------------------------------------------------------------------
-- EventDisposition — what happened when an event arrived at the router.
---------------------------------------------------------------------------

||| What happened to an event after it was submitted to the router.
||| Tag values: Consumed=0, Ignored=1, Queued=2, Dropped=3
public export
data EventDisposition : Type where
  ||| The event was consumed — routed to a matching automation target.
  Consumed : EventDisposition
  ||| The event was ignored — no routing rule matched (dead-letter candidate).
  Ignored  : EventDisposition
  ||| The event was queued — target temporarily unavailable, will retry.
  Queued   : EventDisposition
  ||| The event was dropped — queue overflow or circuit-breaker open.
  Dropped  : EventDisposition

public export
Show EventDisposition where
  show Consumed = "Consumed"
  show Ignored  = "Ignored"
  show Queued   = "Queued"
  show Dropped  = "Dropped"

||| Convert EventDisposition to C-compatible tag value.
public export
eventDispositionToTag : EventDisposition -> Bits8
eventDispositionToTag Consumed = 0
eventDispositionToTag Ignored  = 1
eventDispositionToTag Queued   = 2
eventDispositionToTag Dropped  = 3

||| Convert C tag value back to EventDisposition.
public export
tagToEventDisposition : Bits8 -> Maybe EventDisposition
tagToEventDisposition 0 = Just Consumed
tagToEventDisposition 1 = Just Ignored
tagToEventDisposition 2 = Just Queued
tagToEventDisposition 3 = Just Dropped
tagToEventDisposition _ = Nothing

---------------------------------------------------------------------------
-- Valid router transitions — matches proven-fsm transition schema.
---------------------------------------------------------------------------

||| Proof witness that a transition from one RouterState to another is valid.
||| Only these transitions are allowed:
|||   Configuring -> Routing   (start routing)
|||   Routing     -> Shutdown  (graceful shutdown)
|||   Routing     -> Failed    (unrecoverable error)
|||   Configuring -> Failed    (configuration error)
|||   Failed      -> Configuring (reset after failure)
public export
data ValidRouterTransition : RouterState -> RouterState -> Type where
  ||| Configuring -> Routing: all targets discovered, start dispatching.
  StartRouting     : ValidRouterTransition Configuring Routing
  ||| Routing -> Shutdown: initiate graceful shutdown.
  InitiateShutdown : ValidRouterTransition Routing Shutdown
  ||| Routing -> Failed: unrecoverable error during event dispatch.
  RoutingFault     : ValidRouterTransition Routing Failed
  ||| Configuring -> Failed: configuration or discovery error.
  ConfigFault      : ValidRouterTransition Configuring Failed
  ||| Failed -> Configuring: reset and reconfigure after failure.
  ResetRouter      : ValidRouterTransition Failed Configuring

---------------------------------------------------------------------------
-- HAR-specific constants
---------------------------------------------------------------------------

||| ABI version for HAR's proven-fsm integration.
||| Increment when FFI signatures or tag values change.
public export
harFsmAbiVersion : Bits32
harFsmAbiVersion = 1

||| Maximum number of concurrent router instances.
public export
maxRouterInstances : Nat
maxRouterInstances = 16
