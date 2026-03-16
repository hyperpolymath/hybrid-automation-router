// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Error types for HAR operations

use thiserror::Error;

/// Core error type for HAR operations
#[derive(Error, Debug)]
pub enum Error {
    #[error("Routing error: {0}")]
    Routing(String),

    #[error("No target found for event: {0}")]
    NoTarget(String),

    #[error("Target unavailable: {target} — {reason}")]
    TargetUnavailable { target: String, reason: String },

    #[error("Configuration error: {0}")]
    Config(String),

    #[error("Event validation failed: {0}")]
    InvalidEvent(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("{0}")]
    Other(#[from] anyhow::Error),
}

/// Result type alias for HAR operations
pub type Result<T> = std::result::Result<T, Error>;
