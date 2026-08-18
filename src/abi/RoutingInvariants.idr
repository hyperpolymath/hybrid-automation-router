-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- RoutingInvariants — the three load-bearing claims of the Hybrid
-- Automation Router, written as Idris2 *types* with mechanised proofs.
--
-- The intended invariants are documented in prose in `LinearRouting.eph`
-- ("no silent drops; exactly one dispatch; explicit connection lifetime").
-- This module moves them from comments to mechanised statements, so the
-- in-flight set, dispatch trace, and decision function are all visible to
-- the type checker rather than to readers' eyes only.
--
-- Status (2026-07-06): all 3 invariants PROVED, zero holes, under
-- `%default total`. Two are CONDITIONAL on a premise discharged elsewhere
-- and REUSED here rather than re-proved (the whole point of the proven-* /
-- Ephapax split):
--   * INVARIANT 1 (no event loss)          — noEventLoss
--       premise: proven-queueconn dead-letter termination (`processed`).
--   * INVARIANT 2 (no duplicate dispatch)  — noDuplicateDispatch : LTE n 1
--       premise: Ephapax linear-token discipline (`LinearIn`).
--   * INVARIANT 3 (deterministic + sound)  — deterministicSelection
--       + selectionSound; unconditional (HAR-specific, list-fold selector).
-- See issue #49 and PROOF-NEEDS.md. Wired into `verify-abi`
-- (`idris2 --build har-abi.ipkg`).

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

||| `NoDeliverE e trace`: no `Delivered e _` node occurs anywhere in `trace`.
public export
data NoDeliverE : EventId -> Trace -> Type where
  NDNil  : NoDeliverE e []
  NDStep : {o : Outcome} ->
           (case o of
             Delivered e' _ => Not (e = e')
             _              => Unit) ->
           NoDeliverE e rest ->
           NoDeliverE e (o :: rest)

||| The Ephapax linear-token discipline (`src/abi/LinearRouting.eph`): every
||| accepted event carries exactly ONE linear delivery token, consumed by its
||| single `Delivered` step, so a well-formed trace has AT MOST ONE
||| `Delivered e _`. `LinearIn e trace` is that premise. It is DISCHARGED by
||| the Ephapax linear type system on the producer side and REUSED here — the
||| exact analogue of how `noEventLoss` reuses the queue layer's `processed`
||| guarantee rather than re-proving it.
public export
data LinearIn : EventId -> Trace -> Type where
  LinNil   : LinearIn e []
  ||| A `Delivered e _` node: there must be no further `Delivered e _` after it.
  LinDeliv : NoDeliverE e rest -> LinearIn e (Delivered e t :: rest)
  ||| Any node that is not `Delivered e _`: skip and continue.
  LinSkip  : {o : Outcome} ->
             (case o of
               Delivered e' _ => Not (e = e')
               _              => Unit) ->
             LinearIn e rest ->
             LinearIn e (o :: rest)

||| Lemma: if the trace never delivers `e`, then `e`'s dispatch count (to any
||| target) is exactly zero — the only count-increasing rule is `DCHit`, which
||| requires a `Delivered e t` node that `NoDeliverE` rules out.
export
noDeliverZeroCount : NoDeliverE e rest -> DispatchCount e t rest n -> n = Z
noDeliverZeroCount NDNil          DCNil          = Refl
noDeliverZeroCount (NDStep g _)   (DCHit _)      = void (g Refl)
noDeliverZeroCount (NDStep _ nd)  (DCMissE _ dc) = noDeliverZeroCount nd dc
noDeliverZeroCount (NDStep _ nd)  (DCMissT _ dc) = noDeliverZeroCount nd dc

||| INVARIANT 2 (no duplicate dispatch): under the Ephapax linear-token
||| premise (`LinearIn e trace`), every (event, target) pair is delivered AT
||| MOST ONCE — the dispatch count is bounded by 1. This is the exactly-once
||| upper bound; `noEventLoss` supplies the matching lower bound (at least one
||| terminal outcome), and together they are "exactly once".
export
noDuplicateDispatch :
  (e : EventId) ->
  (t : TargetId) ->
  (trace : Trace) ->
  {n : Nat} ->
  LinearIn e trace ->
  DispatchCount e t trace n ->
  LTE n 1
noDuplicateDispatch e t trace lin dc = case dc of
  DCNil         => LTEZero
  DCHit dc'     => case lin of
                     LinDeliv nd => rewrite noDeliverZeroCount nd dc' in LTESucc LTEZero
                     LinSkip g _ => void (g Refl)
  DCMissE g dc' => case lin of
                     LinSkip _ lin' => noDuplicateDispatch e t _ lin' dc'
                     LinDeliv _     => void (g Refl)
  DCMissT _ dc' => case lin of
                     LinSkip _ lin' => noDuplicateDispatch e t _ lin' dc'
                     LinDeliv nd    => rewrite noDeliverZeroCount nd dc' in LTEZero

----------------------------------------------------------------------------
-- INVARIANT 3 — deterministic, sound target selection.
--
-- We model selection CONCRETELY as a fold over the candidate *list* (never a
-- HashMap). That is exactly why determinism holds: there is no iteration
-- order to leak into the decision. `better` is the total tie-break oracle
-- (score, then TargetId) the Rust selector realises; we need only that it is
-- a pure function to get determinism, and nothing about it to get soundness.
----------------------------------------------------------------------------

||| One step of the max-fold: keep whichever of `best`/`y` the `better`
||| predicate prefers, threading the choice through the remaining candidates.
public export
selectFold : (better : TargetId -> TargetId -> Bool) ->
             TargetId -> List TargetId -> TargetId
selectFold better best []        = best
selectFold better best (y :: ys) =
  if better y best then selectFold better y ys else selectFold better best ys

||| The fold's result is always either the running `best` or one of the
||| remaining candidates — never a value that was not offered.
export
selectFoldMem : (better : TargetId -> TargetId -> Bool) ->
                (best : TargetId) -> (xs : List TargetId) ->
                Either (selectFold better best xs = best)
                       (Elem (selectFold better best xs) xs)
selectFoldMem better best []        = Left Refl
selectFoldMem better best (y :: ys) with (better y best)
  _ | True  = case selectFoldMem better y ys of
                Left  eq => Right (rewrite eq in Here)
                Right el => Right (There el)
  _ | False = case selectFoldMem better best ys of
                Left  eq => Left eq
                Right el => Right (There el)

||| Deterministic selection: pick the maximal candidate under `better`.
||| `Nothing` exactly when there are no candidates.
public export
pickMax : (better : TargetId -> TargetId -> Bool) -> List TargetId -> Maybe TargetId
pickMax better []        = Nothing
pickMax better (x :: xs) = Just (selectFold better x xs)

||| INVARIANT 3a (determinism): selection is a pure function of its inputs —
||| same candidates, same tie-break, same answer. Trivial BY CONSTRUCTION
||| because it folds the candidate list rather than iterating a HashMap: there
||| is no ordering input for the decision to diverge on. (This is the exact
||| bug the Rust selector was rewritten to avoid in #87.)
export
deterministicSelection :
  (better : TargetId -> TargetId -> Bool) ->
  (cands  : List TargetId) ->
  pickMax better cands = pickMax better cands
deterministicSelection better cands = Refl

||| INVARIANT 3b (soundness): the selected target is always one of the
||| candidates. The router never invents a target it was not given. This is
||| the non-vacuous half — and it holds for ANY tie-break `better`.
export
selectionSound :
  (better : TargetId -> TargetId -> Bool) ->
  (cands  : List TargetId) ->
  (t      : TargetId) ->
  pickMax better cands = Just t ->
  Elem t cands
selectionSound better []        t Refl impossible
selectionSound better (x :: xs) t prf = case prf of
  Refl => case selectFoldMem better x xs of
            Left  eq => rewrite eq in Here
            Right el => There el

-- vim: ft=idris2
