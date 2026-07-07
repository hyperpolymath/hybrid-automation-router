// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Error types for the meta-model

use crate::state::RealisationStatus;

/// Errors produced by meta-model operations
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A resource with this id is already in the graph
    #[error("duplicate resource id: {0}")]
    DuplicateResource(String),

    /// A referenced resource id is not in the graph
    #[error("unknown resource id: {0}")]
    UnknownResource(String),

    /// The dependency edges contain a cycle (ids on the cycle, in order)
    #[error("dependency cycle: {}", .0.join(" -> "))]
    DependencyCycle(Vec<String>),

    /// A lifecycle transition not permitted by the realisation FSM
    #[error("invalid lifecycle transition: {from} -> {to}")]
    InvalidTransition {
        /// Status the resource is currently in
        from: RealisationStatus,
        /// Status the transition attempted to reach
        to: RealisationStatus,
    },

    /// A handoff that would violate linear ownership
    #[error("handoff violation: {0}")]
    HandoffViolation(String),

    /// An identifier or name outside the meta-model's permitted charset
    #[error("invalid identifier {what}: {value:?}")]
    InvalidIdentifier {
        /// Which kind of identifier was rejected
        what: &'static str,
        /// The offending value
        value: String,
    },

    /// The A2ML interchange text could not be parsed
    #[error("a2ml parse error at line {line}: {message}")]
    Parse {
        /// 1-indexed line number of the offending input
        line: usize,
        /// What went wrong
        message: String,
    },

    /// A value the current dialect version cannot represent
    #[error("not representable in dialect v{version}: {message}")]
    Unrepresentable {
        /// Dialect version that rejected the value
        version: &'static str,
        /// What could not be represented
        message: String,
    },
}

/// Result alias for meta-model operations
pub type Result<T> = std::result::Result<T, Error>;
