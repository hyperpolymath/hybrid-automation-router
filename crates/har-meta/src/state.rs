// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! The per-resource realisation lifecycle
//!
//! `declared -> planned -> realised`, with `handed-off` reachable from any
//! of the three (ADR-0002 handoff explicitly covers *partially-realised*
//! estates, so a resource may be handed off before it is planned or
//! realised). `handed-off` is terminal for the side that exported it.
//!
//! The normative transition relation lives in `src/abi/MetaModel.idr`
//! (`Step`); this enum and [`RealisationStatus::can_advance`] must stay in
//! sync with it.

use serde::{Deserialize, Serialize};

/// Where a resource is in its realisation lifecycle
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RealisationStatus {
    /// Desired, present in the graph, nothing computed yet
    Declared,
    /// A plan realising it has been computed
    Planned,
    /// The plan executed; the resource exists as declared
    Realised,
    /// Realisation responsibility transferred to another owner (terminal
    /// on the exporting side)
    HandedOff,
}

impl RealisationStatus {
    /// Whether the lifecycle FSM permits moving from `self` to `to`
    pub fn can_advance(self, to: Self) -> bool {
        use RealisationStatus::*;
        matches!(
            (self, to),
            (Declared, Planned) | (Planned, Realised) | (Declared | Planned | Realised, HandedOff)
        )
    }

    /// Whether no transition leaves this status
    pub fn is_terminal(self) -> bool {
        self == Self::HandedOff
    }

    /// Kebab-case name as carried in the A2ML dialect
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Declared => "declared",
            Self::Planned => "planned",
            Self::Realised => "realised",
            Self::HandedOff => "handed-off",
        }
    }

    /// Parse the kebab-case dialect name
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "declared" => Some(Self::Declared),
            "planned" => Some(Self::Planned),
            "realised" => Some(Self::Realised),
            "handed-off" => Some(Self::HandedOff),
            _ => None,
        }
    }
}

impl std::fmt::Display for RealisationStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use RealisationStatus::*;

    const ALL: [RealisationStatus; 4] = [Declared, Planned, Realised, HandedOff];

    #[test]
    fn test_happy_path() {
        assert!(Declared.can_advance(Planned));
        assert!(Planned.can_advance(Realised));
        assert!(Realised.can_advance(HandedOff));
    }

    #[test]
    fn test_partial_handoff_allowed() {
        assert!(Declared.can_advance(HandedOff));
        assert!(Planned.can_advance(HandedOff));
    }

    #[test]
    fn test_no_skip_no_regress() {
        assert!(!Declared.can_advance(Realised));
        assert!(!Planned.can_advance(Declared));
        assert!(!Realised.can_advance(Planned));
        assert!(!Realised.can_advance(Declared));
    }

    #[test]
    fn test_handed_off_terminal() {
        for to in ALL {
            assert!(!HandedOff.can_advance(to));
        }
        assert!(HandedOff.is_terminal());
    }

    #[test]
    fn test_str_round_trip() {
        for s in ALL {
            assert_eq!(RealisationStatus::parse(s.as_str()), Some(s));
        }
        assert_eq!(RealisationStatus::parse("bogus"), None);
    }
}
