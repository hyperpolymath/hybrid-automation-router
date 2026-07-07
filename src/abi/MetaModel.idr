-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-- Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

||| MetaModel — normative specification of the automation meta-model
|||
||| ADR-0002 "parallel tracks": this module is the source of truth for the
||| meta-model's shape and invariants; `crates/har-meta` is the executable
||| Rust mirror and must be kept in sync with it by hand. Where the two
||| disagree, this file wins and the Rust changes.
module MetaModel

%default total

------------------------------------------------------------------------------
-- Realisation lifecycle
------------------------------------------------------------------------------

||| Where a resource is in its realisation lifecycle.
public export
data RealisationStatus
  = ||| Desired, present in the graph, nothing computed yet
    Declared
  | ||| A plan realising it has been computed
    Planned
  | ||| The plan executed; the resource exists as declared
    Realised
  | ||| Realisation responsibility transferred to another owner
    HandedOff

public export
Eq RealisationStatus where
  Declared  == Declared  = True
  Planned   == Planned   = True
  Realised  == Realised  = True
  HandedOff == HandedOff = True
  _         == _         = False

||| The permitted lifecycle transitions — the normative FSM.
|||
||| `declared -> planned -> realised` is the realisation path; `handed-off`
||| is reachable from ANY non-terminal status because ADR-0002's handoff
||| explicitly covers partially-realised estates. Nothing leaves
||| `handed-off`: it is terminal on the exporting side.
public export
data Step : RealisationStatus -> RealisationStatus -> Type where
  DeclareToPlan   : Step Declared Planned
  PlanToRealise   : Step Planned Realised
  HandOffDeclared : Step Declared HandedOff
  HandOffPlanned  : Step Planned HandedOff
  HandOffRealised : Step Realised HandedOff

||| `handed-off` is terminal: no step leaves it.
export
handedOffTerminal : Step HandedOff s -> Void
handedOffTerminal DeclareToPlan   impossible
handedOffTerminal PlanToRealise   impossible
handedOffTerminal HandOffDeclared impossible
handedOffTerminal HandOffPlanned  impossible
handedOffTerminal HandOffRealised impossible

||| The lifecycle never regresses: no step re-enters `declared`.
export
noStepToDeclared : Step s Declared -> Void
noStepToDeclared DeclareToPlan   impossible
noStepToDeclared PlanToRealise   impossible
noStepToDeclared HandOffDeclared impossible
noStepToDeclared HandOffPlanned  impossible
noStepToDeclared HandOffRealised impossible

||| Zero or more lifecycle steps (the reachability relation).
public export
data Path : RealisationStatus -> RealisationStatus -> Type where
  Here  : Path s s
  There : Step a b -> Path b c -> Path a c

||| Every status can reach `handed-off`: any resource, however far its
||| realisation has progressed, can be handed to another owner.
export
alwaysHandoffable : (s : RealisationStatus) -> Path s HandedOff
alwaysHandoffable Declared  = There HandOffDeclared Here
alwaysHandoffable Planned   = There HandOffPlanned Here
alwaysHandoffable Realised  = There HandOffRealised Here
alwaysHandoffable HandedOff = Here

------------------------------------------------------------------------------
-- Dependencies
------------------------------------------------------------------------------

||| The kind of a dependency edge. All three impose ordering; `Notify`
||| additionally refreshes its successor.
public export
data DependencyKind = Before | Require | Notify

||| The ordering an edge imposes, as (earlier, later), given (from, to).
||| `Before`/`Notify` order `from` earlier; `Require` is the inverse.
public export
ordering : DependencyKind -> (from : rid) -> (to : rid) -> (rid, rid)
ordering Before  from to = (from, to)
ordering Notify  from to = (from, to)
ordering Require from to = (to, from)

------------------------------------------------------------------------------
-- The graph vocabulary
------------------------------------------------------------------------------

||| A desired resource: id, tool-neutral kind, and desired attributes
||| (attribute values are abstract here; the Rust mirror fixes them to the
||| dialect's scalar universe).
public export
record Resource rid attr where
  constructor MkResource
  resourceId : rid
  kind       : String
  attributes : List (String, attr)

||| A dependency edge between two resources.
public export
record Dependency rid where
  constructor MkDependency
  from : rid
  to   : rid
  dep  : DependencyKind

||| Provenance: current owner and status. (The append-only history is an
||| implementation artefact of the mirror; its invariant is that `owner`
||| and `status` are the fold of the recorded events.)
public export
record Provenance where
  constructor MkProvenance
  owner  : String
  status : RealisationStatus

||| A graph entry: resource + provenance + optional selected provider.
public export
record Entry rid attr where
  constructor MkEntry
  resource   : Resource rid attr
  provenance : Provenance
  provider   : Maybe String

------------------------------------------------------------------------------
-- Normative obligations for the executable mirror (checked by tests there,
-- proven here as the model matures):
--
--  1. Resource ids are unique within a graph.
--  2. Dependency endpoints name resources present in the graph.
--  3. Lowering (graph -> plan) is defined only for acyclic `ordering`
--     projections of the edge set, and emits a topological order that is
--     deterministic for equal graphs.
--  4. Handoff transfers ownership of a resource set exactly once
--     (linearity), atomically (all-or-nothing), never from a terminal
--     status, and preserves each resource's RealisationStatus.
------------------------------------------------------------------------------
