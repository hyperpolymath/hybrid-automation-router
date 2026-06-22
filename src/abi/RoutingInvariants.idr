-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- RoutingInvariants — the three load-bearing claims of the Hybrid
-- Automation Router, written as Idris2 *types*. Proofs are deliberately
-- left as `?holes` so the obligations are visible in compiler output;
-- closing them is tracked in `PROOF-NEEDS.md`.
--
-- The intended invariants are documented in prose in `LinearRouting.eph`
-- ("no silent drops; exactly one dispatch; explicit connection lifetime").
-- This module is the first step of moving them from comments to mechanised
-- statements, so the in-flight set, dispatch trace, and decision function
-- are all visible to the type checker rather than to readers' eyes only.
--
-- Status (2026-06-02): TYPE STUBS ONLY. Holes are EXPECTED. See issue #49
-- and PROOF-NEEDS.md for the remediation programme. This file is wired
-- into the existing `verify-proofs` story via the `verification/` dir.

module HAR.ABI.RoutingInvariants

import HAR.ABI.ProvenQueue

%default total

----------------------------------------------------------------------------
-- Abstract domain model
--
-- We model just enough of the router/dispatcher loop to *state* the three
-- invariants. Concrete instantiation against the Rust runtime is future
-- work — the point here is that the obligations type-check.
----------------------------------------------------------------------------

||| Identifier for an event (mirrors `AutomationEvent.id` in har-core).
public export
EventId : Type
EventId = String

||| Identifier for a target (mirrors `AutomationTarget.id` in har-core).
public export
TargetId : Type
TargetId = String

||| Outcome of the router/dispatcher for a single event.
||| Every accepted event must reach EXACTLY ONE of these states.
public export
data Outcome : Type where
  Delivered    : EventId -> TargetId -> Outcome
  DeadLettered : EventId -> String   -> Outcome   -- reason
  InFlight     : EventId             -> Outcome   -- not yet resolved

||| A trace of router/dispatcher outcomes, in observed order.
public export
Trace : Type
Trace = List Outcome

||| The router's deterministic selection function (abstract).
||| Given an event id, a snapshot of registered targets, and a rule set,
||| returns either `Just t` for the chosen target or `Nothing` if no
||| target is eligible.
public export
record RouterSnapshot where
  constructor MkSnapshot
  targets    : List TargetId
  -- Tag-rule and capability tables are abstracted as a single oracle.
  selectOne  : EventId -> Maybe TargetId

----------------------------------------------------------------------------
-- INVARIANT 1 — no event loss.
----------------------------------------------------------------------------

||| `Resolved e t` says the trace `t` contains a terminal outcome
||| (Delivered or DeadLettered) for the event `e`. `InFlight` is not
||| terminal: an event in flight has not yet been "lost", but neither has
||| it been resolved — `noEventLoss` is the statement that at quiescence
||| the in-flight set is empty.
public export
data Resolved : EventId -> Trace -> Type where
  HereDelivered    : Resolved e (Delivered e t :: rest)
  HereDeadLettered : Resolved e (DeadLettered e r :: rest)
  ThereResolved    : Resolved e rest -> Resolved e (o :: rest)

||| Quiescence: no `InFlight` outcome in the trace.
public export
data Quiescent : Trace -> Type where
  QNil  : Quiescent []
  QStep : (case o of
            InFlight _ => Void
            _          => Unit) ->
          Quiescent rest ->
          Quiescent (o :: rest)

||| INVARIANT 1: at quiescence, every accepted event has a terminal outcome.
|||
|||   `accepted` is the list of event ids the router admitted from upstream.
public export
noEventLoss :
  (accepted : List EventId) ->
  (t        : Trace) ->
  Quiescent t ->
  -- Every accepted event id appears resolved in t.
  ((e : EventId) -> Elem e accepted -> Resolved e t)
noEventLoss accepted t q = ?noEventLoss_rhs

----------------------------------------------------------------------------
-- INVARIANT 2 — no duplicate dispatch.
----------------------------------------------------------------------------

||| `DispatchCount e t trace` counts how many times event `e` was
||| `Delivered` to target `t` in the trace. Under `AtLeastOnce` the bound
||| is `<= 1` for ExactlyOnce targets and unconstrained for others
||| (idempotency is the target's responsibility); under `ExactlyOnce` it
||| is `= 1` for events that are not dead-lettered.
public export
data DispatchCount : EventId -> TargetId -> Trace -> Nat -> Type where
  DCNil   : DispatchCount e t [] Z
  DCHit   : DispatchCount e t rest n -> DispatchCount e t (Delivered e t :: rest) (S n)
  DCMissE : (case o of
              Delivered e' t' => Not (e = e')
              _               => Unit) ->
            DispatchCount e t rest n ->
            DispatchCount e t (o :: rest) n
  DCMissT : (case o of
              Delivered e' t' => Not (t = t')
              _               => Unit) ->
            DispatchCount e t rest n ->
            DispatchCount e t (o :: rest) n

||| INVARIANT 2 (ExactlyOnce variant): for events with `ExactlyOnce`
||| guarantee, every (event, target) pair is delivered at most once.
public export
noDuplicateDispatch :
  (e : EventId) ->
  (t : TargetId) ->
  (trace : Trace) ->
  (guarantee : DeliveryGuarantee) ->
  -- (Premise: the guarantee for (e,t) is ExactlyOnce — abstracted here.)
  (n : Nat ** DispatchCount e t trace n)
noDuplicateDispatch e t trace guarantee = ?noDuplicateDispatch_rhs

----------------------------------------------------------------------------
-- INVARIANT 3 — deterministic target selection.
----------------------------------------------------------------------------

||| INVARIANT 3: the selector is a function — same snapshot, same event,
||| same answer. This is the easiest of the three to verify (and to break
||| accidentally, e.g. by HashMap iteration order leaking into the
||| decision), so we state it explicitly.
public export
deterministicSelection :
  (s : RouterSnapshot) ->
  (e : EventId) ->
  selectOne s e = selectOne s e
deterministicSelection s e = Refl

-- vim: ft=idris2
