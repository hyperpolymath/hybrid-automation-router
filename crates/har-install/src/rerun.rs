// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Version pinning and re-run/upgrade policy.
//!
//! The declarative half of tier 1 is "ensure `name` is installed at version
//! X". [`VersionSpec`] carries that intent; [`RerunPolicy`] says what happens
//! when a realised artefact is reconciled again — the difference between a
//! pinned tool that must never drift and a `curl | sh` script that re-runs to
//! pick up the latest.

use serde::{Deserialize, Serialize};

/// The version intent of a declared install.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum VersionSpec {
    /// Whatever the origin currently yields (the `curl | sh` "latest"
    /// default). Not reproducible; recorded honestly.
    Latest,
    /// A pinned exact version string (e.g. `14.1.0`). Reproducible.
    Exact {
        /// The pinned version.
        version: String,
    },
}

impl VersionSpec {
    /// An exact pin.
    pub fn exact(v: impl Into<String>) -> Self {
        Self::Exact { version: v.into() }
    }

    /// The recorded version string, or `latest` for the unpinned case.
    pub fn as_str(&self) -> &str {
        match self {
            Self::Latest => "latest",
            Self::Exact { version } => version,
        }
    }

    /// Parse the recorded string form back to a spec.
    pub fn parse(s: &str) -> Self {
        if s == "latest" {
            Self::Latest
        } else {
            Self::Exact {
                version: s.to_string(),
            }
        }
    }

    /// Whether the spec pins a reproducible version.
    pub fn is_pinned(&self) -> bool {
        matches!(self, Self::Exact { .. })
    }
}

/// What reconciling an already-realised artefact should do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RerunPolicy {
    /// Already installed at the pinned version ⇒ do nothing. The safe default
    /// for pinned provers/solvers.
    IdempotentSkip,
    /// Re-run the origin every reconcile (a `curl | sh` "always latest"
    /// script). Not idempotent by nature; flagged so a planner can warn.
    AlwaysReinstall,
    /// Reinstall only when the pinned version differs from what is realised.
    UpgradeOnVersionChange,
}

impl RerunPolicy {
    /// Stable kebab-case tag.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::IdempotentSkip => "idempotent-skip",
            Self::AlwaysReinstall => "always-reinstall",
            Self::UpgradeOnVersionChange => "upgrade-on-version-change",
        }
    }

    /// Parse the kebab-case tag.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "idempotent-skip" => Some(Self::IdempotentSkip),
            "always-reinstall" => Some(Self::AlwaysReinstall),
            "upgrade-on-version-change" => Some(Self::UpgradeOnVersionChange),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_round_trip() {
        assert_eq!(VersionSpec::parse("latest"), VersionSpec::Latest);
        assert_eq!(VersionSpec::parse("1.2.3"), VersionSpec::exact("1.2.3"));
        assert!(!VersionSpec::Latest.is_pinned());
        assert!(VersionSpec::exact("1.2.3").is_pinned());
    }

    #[test]
    fn policy_round_trip() {
        for p in [
            RerunPolicy::IdempotentSkip,
            RerunPolicy::AlwaysReinstall,
            RerunPolicy::UpgradeOnVersionChange,
        ] {
            assert_eq!(RerunPolicy::parse(p.as_str()), Some(p));
        }
    }
}
