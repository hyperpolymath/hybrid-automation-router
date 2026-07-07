// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Handoff — linear ownership transfer with a checkpoint
//!
//! A handoff moves responsibility for a set of resources from one owner to
//! another, exactly once (ADR-0002: "a linear ownership transfer with a
//! checkpoint"). The [`HandoffCheckpoint`] is the record of one completed
//! transfer; the transfer itself is [`crate::ResourceGraph::hand_off`],
//! which validates ownership and appends to each resource's provenance.
//!
//! Note the two sides of a handoff: in the shared federated view the
//! resource simply changes owner and keeps its realisation status (a
//! *partially-realised* estate is the flagship case). `handed-off` as a
//! [`crate::RealisationStatus`] is the exporting tool's terminal marker in
//! its own local view. The full linear-types treatment (no double-apply
//! across a handoff, machine-checked) is specified in
//! `src/abi/LinearRouting.eph` and arrives with the handoff engine, not
//! this skeleton.

use crate::provenance::Owner;
use crate::resource::ResourceId;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// The record of one completed ownership transfer
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandoffCheckpoint {
    /// Owner the resources transferred from
    pub from: Owner,
    /// Owner the resources transferred to
    pub to: Owner,
    /// The resources transferred (sorted, no duplicates)
    pub resources: Vec<ResourceId>,
    /// When the transfer happened
    pub at: DateTime<Utc>,
}
