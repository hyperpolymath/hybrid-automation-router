// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! HAR Meta — The automation meta-model (Phase 2A skeleton)
//!
//! The tool-neutral ontology behind the automation interlingua decided in
//! ADR-0002: a schema onto which each automation tool's concepts are mapped,
//! carried on A2ML, doubling as an execution IR when HAR runs it natively.
//!
//! # Key Types
//!
//! - [`Resource`] — A desired thing with a kind and attributes
//! - [`Dependency`] — An ordering/refresh edge between resources
//! - [`RealisationStatus`] — The per-resource lifecycle (`declared ->
//!   planned -> realised`, with `handed-off` reachable from any of them)
//! - [`Provenance`] — Who owns a resource now, and the history of how it
//!   got here (the load-bearing record for cross-tool handoff)
//! - [`ResourceGraph`] — The declarative level of the two-level IR: resources
//!   plus dependency edges, with cycle detection and a deterministic
//!   execution order (the seed of lowering)
//! - [`a2ml`] — Emit/parse the A2ML interchange dialect (v0.1)
//!
//! The normative reference for this model is the Idris2 specification in
//! `src/abi/MetaModel.idr`; the two are kept in sync by hand (ADR-0002
//! "parallel tracks"). This crate is deliberately independent of `har-core`:
//! the meta-model is domain-neutral, and the routing-domain binding arrives
//! with the two-level IR (`har-il`).

#![forbid(unsafe_code)]
pub mod a2ml;
pub mod dependency;
pub mod error;
pub mod graph;
pub mod handoff;
pub mod provenance;
pub mod resource;
pub mod state;

pub use dependency::{Dependency, DependencyKind};
pub use error::{Error, Result};
pub use graph::{ResourceEntry, ResourceGraph};
pub use handoff::HandoffCheckpoint;
pub use provenance::{Owner, Provenance, ProvenanceAction, ProvenanceEntry, Provider};
pub use resource::{AttrValue, Resource, ResourceId, ResourceKind};
pub use state::RealisationStatus;
