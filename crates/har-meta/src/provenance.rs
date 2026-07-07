// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Provenance — who owns a resource now, and how it got here
//!
//! Handoff and resume make provenance load-bearing (ADR-0002): every
//! resource carries its current owner, its realisation status, and an
//! append-only history. The history is checkpoint metadata — the A2ML
//! dialect v0.1 carries only the current owner and status.

use crate::error::{Error, Result};
use crate::state::RealisationStatus;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// The tool or system currently responsible for a resource
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Owner(String);

impl Owner {
    /// Create an owner name (non-empty)
    pub fn new(name: impl Into<String>) -> Result<Self> {
        let name = name.into();
        if name.is_empty() {
            return Err(Error::InvalidIdentifier {
                what: "owner",
                value: name,
            });
        }
        Ok(Self(name))
    }

    /// The owner name as a string slice
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for Owner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// The provider that realises a resource (e.g. a package manager adapter)
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Provider(String);

impl Provider {
    /// Create a provider name (non-empty)
    pub fn new(name: impl Into<String>) -> Result<Self> {
        let name = name.into();
        if name.is_empty() {
            return Err(Error::InvalidIdentifier {
                what: "provider",
                value: name,
            });
        }
        Ok(Self(name))
    }

    /// The provider name as a string slice
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for Provider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// One recorded provenance event
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProvenanceEntry {
    /// When it happened
    pub at: DateTime<Utc>,
    /// What happened
    pub action: ProvenanceAction,
}

/// What a provenance entry records
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "action")]
pub enum ProvenanceAction {
    /// The resource entered the graph under an owner
    Declared {
        /// Initial owner
        owner: Owner,
    },
    /// The lifecycle advanced
    StatusAdvanced {
        /// Previous status
        from: RealisationStatus,
        /// New status
        to: RealisationStatus,
    },
    /// Ownership transferred as part of a handoff
    OwnershipTransferred {
        /// Previous owner
        from: Owner,
        /// New owner
        to: Owner,
    },
}

/// A resource's provenance: current owner, status, and history
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Provenance {
    /// Current owner
    pub owner: Owner,
    /// Current realisation status
    pub status: RealisationStatus,
    /// Append-only event history (oldest first)
    pub history: Vec<ProvenanceEntry>,
}

impl Provenance {
    /// Provenance for a freshly declared resource
    pub fn declared(owner: Owner, at: DateTime<Utc>) -> Self {
        Self {
            owner: owner.clone(),
            status: RealisationStatus::Declared,
            history: vec![ProvenanceEntry {
                at,
                action: ProvenanceAction::Declared { owner },
            }],
        }
    }

    /// Advance the lifecycle, enforcing the realisation FSM
    pub fn advance(&mut self, to: RealisationStatus, at: DateTime<Utc>) -> Result<()> {
        if !self.status.can_advance(to) {
            return Err(Error::InvalidTransition {
                from: self.status,
                to,
            });
        }
        self.history.push(ProvenanceEntry {
            at,
            action: ProvenanceAction::StatusAdvanced {
                from: self.status,
                to,
            },
        });
        self.status = to;
        Ok(())
    }

    /// Transfer ownership (the handoff move), recording it in history
    ///
    /// A handed-off resource cannot transfer again: `handed-off` is
    /// terminal on the exporting side, so linear ownership is preserved.
    pub fn transfer(&mut self, to: Owner, at: DateTime<Utc>) -> Result<()> {
        if self.status.is_terminal() {
            return Err(Error::HandoffViolation(format!(
                "resource already handed off by {}",
                self.owner
            )));
        }
        if self.owner == to {
            return Err(Error::HandoffViolation(format!(
                "transfer to current owner {to}"
            )));
        }
        self.history.push(ProvenanceEntry {
            at,
            action: ProvenanceAction::OwnershipTransferred {
                from: self.owner.clone(),
                to: to.clone(),
            },
        });
        self.owner = to;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-07-07T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn test_lifecycle_recorded() {
        let mut p = Provenance::declared(Owner::new("har").unwrap(), t0());
        p.advance(RealisationStatus::Planned, t0()).unwrap();
        p.advance(RealisationStatus::Realised, t0()).unwrap();
        assert_eq!(p.status, RealisationStatus::Realised);
        assert_eq!(p.history.len(), 3);
        assert!(p.advance(RealisationStatus::Declared, t0()).is_err());
    }

    #[test]
    fn test_transfer_is_linear() {
        let mut p = Provenance::declared(Owner::new("puppet").unwrap(), t0());
        p.transfer(Owner::new("salt").unwrap(), t0()).unwrap();
        assert_eq!(p.owner.as_str(), "salt");
        // Self-transfer rejected
        assert!(p.transfer(Owner::new("salt").unwrap(), t0()).is_err());
        // After the exporting side marks handed-off, no further transfer
        p.advance(RealisationStatus::HandedOff, t0()).unwrap();
        assert!(p.transfer(Owner::new("ansible").unwrap(), t0()).is_err());
    }
}
