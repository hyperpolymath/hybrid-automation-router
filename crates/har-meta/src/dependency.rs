// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Dependencies — the edges of the declarative level
//!
//! Three edge kinds, following the vocabulary shared by the tools the 2B
//! adapters target (Puppet before/require/notify, Salt require/watch):
//! all three impose ordering; `Notify` additionally carries a refresh
//! signal to its successor.

use crate::resource::ResourceId;
use serde::{Deserialize, Serialize};

/// The kind of a dependency edge
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DependencyKind {
    /// `from` must be realised before `to`
    Before,
    /// `from` requires `to`: `to` must be realised before `from`
    Require,
    /// Like [`DependencyKind::Before`], plus `to` is refreshed whenever
    /// `from` changes
    Notify,
}

impl DependencyKind {
    /// Kebab-case name as carried in the A2ML dialect
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Before => "before",
            Self::Require => "require",
            Self::Notify => "notify",
        }
    }

    /// Parse the kebab-case dialect name
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "before" => Some(Self::Before),
            "require" => Some(Self::Require),
            "notify" => Some(Self::Notify),
            _ => None,
        }
    }
}

/// A directed dependency between two resources
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dependency {
    /// Source resource
    pub from: ResourceId,
    /// Target resource
    pub to: ResourceId,
    /// Edge kind
    pub kind: DependencyKind,
}

impl Dependency {
    /// Create a dependency edge
    pub fn new(from: ResourceId, to: ResourceId, kind: DependencyKind) -> Self {
        Self { from, to, kind }
    }

    /// The ordering this edge imposes, as `(earlier, later)`
    ///
    /// `Before`/`Notify` order `from` earlier than `to`; `Require` is the
    /// inverse (the required resource is realised first).
    pub fn ordering(&self) -> (&ResourceId, &ResourceId) {
        match self.kind {
            DependencyKind::Before | DependencyKind::Notify => (&self.from, &self.to),
            DependencyKind::Require => (&self.to, &self.from),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ordering_direction() {
        let a = ResourceId::new("a").unwrap();
        let b = ResourceId::new("b").unwrap();
        let before = Dependency::new(a.clone(), b.clone(), DependencyKind::Before);
        let require = Dependency::new(a.clone(), b.clone(), DependencyKind::Require);
        let notify = Dependency::new(a.clone(), b.clone(), DependencyKind::Notify);
        assert_eq!(before.ordering(), (&a, &b));
        assert_eq!(require.ordering(), (&b, &a));
        assert_eq!(notify.ordering(), (&a, &b));
    }
}
