// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Errors for the tier-1 install domain.

use thiserror::Error;

/// Anything that can go wrong capturing, lifting, or replaying an install.
#[derive(Debug, Error)]
pub enum Error {
    /// The meta-model rejected an identifier or attribute during mapping.
    #[error("meta-model mapping: {0}")]
    Meta(#[from] har_meta::Error),

    /// An integrity check failed: the fetched bytes do not match the record.
    #[error("integrity mismatch for {name}: expected {expected}, got {actual}")]
    IntegrityMismatch {
        /// Artifact name.
        name: String,
        /// Digest recorded in the artifact.
        expected: String,
        /// Digest computed over the acquired bytes.
        actual: String,
    },

    /// A footprint file operation failed on the host.
    #[error("footprint I/O at {path}: {message}")]
    Io {
        /// Path being placed or removed (record-relative).
        path: String,
        /// Underlying cause.
        message: String,
    },

    /// Lifting was asked to read a resource that is not a `pkg.install`.
    #[error("lift: resource kind {0} is not a tier-1 install artifact")]
    NotAnArtifact(String),

    /// Lifting found a required attribute missing.
    #[error("lift: missing required attribute `{0}`")]
    MissingAttr(&'static str),

    /// Lifting found an attribute of the wrong shape or an unknown enum tag.
    #[error("lift: attribute `{attr}` is malformed: {detail}")]
    BadAttr {
        /// Attribute name.
        attr: &'static str,
        /// What was wrong.
        detail: String,
    },
}

/// Convenient result alias for the crate.
pub type Result<T> = std::result::Result<T, Error>;
