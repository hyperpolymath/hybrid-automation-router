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

module RoutingInvariants

import ProvenQueue
import Data.List.Elem

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
  QStep : {o : Outcome} ->
          (case o of
            InFlight _ => Void
            _          => Unit) ->
          Quiescent rest ->
          Quiescent (o :: rest)

||| INVARIANT 1: at quiescence, every accepted event has a terminal outcome.
|||
|||   `accepted` is the list of event ids the router admitted from upstream.
||| `Appears e t`: the trace records some outcome for `e` — terminal
||| (Delivered/DeadLettered) or not-yet (InFlight). This is what the dispatch
||| loop guarantees for every accepted event: proven-queueconn's dead-letter
||| termination says every enqueued event eventually reaches the trace.
public export
data Appears : EventId -> Trace -> Type where
  AppDelivered    : Appears e (Delivered e tgt :: rest)
  AppDeadLettered : Appears e (DeadLettered e r :: rest)
  AppInFlight     : Appears e (InFlight e :: rest)
  AppThere        : Appears e rest -> Appears e (o :: rest)

||| Load-bearing lemma: at quiescence (no InFlight in the trace), anything that
||| appears is resolved — quiescence rules out the only non-terminal case.
export
appearsResolvedAtQuiescence : Quiescent t -> Appears e t -> Resolved e t
appearsResolvedAtQuiescence (QStep _ _)  AppDelivered    = HereDelivered
appearsResolvedAtQuiescence (QStep _ _)  AppDeadLettered = HereDeadLettered
appearsResolvedAtQuiescence (QStep nf _) AppInFlight     = absurd nf
appearsResolvedAtQuiescence (QStep _ qr) (AppThere a)    =
  ThereResolved (appearsResolvedAtQuiescence qr a)

||| INVARIANT 1 (no event loss): at quiescence, every accepted event that the
||| dispatch loop processed — i.e. that `Appears` in the trace, the guarantee
||| the proven-queueconn layer provides — has a terminal outcome. The
||| `processed` premise is exactly where the queue-layer guarantee is *reused*
||| rather than re-proved here.
public export
noEventLoss :
  (accepted  : List EventId) ->
  (t         : Trace) ->
  (quiescent : Quiescent t) ->
  (processed : (e : EventId) -> Elem e accepted -> Appears e t) ->
  ((e : EventId) -> Elem e accepted -> Resolved e t)
noEventLoss accepted t quiescent processed e prf =
  appearsResolvedAtQuiescence quiescent (processed e prf)

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
  DCMissE : {o : Outcome} ->
            (case o of
              Delivered e' t' => Not (e = e')
              _               => Unit) ->
            DispatchCount e t rest n ->
            DispatchCount e t (o :: rest) n
  DCMissT : {o : Outcome} ->
            (case o of
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
