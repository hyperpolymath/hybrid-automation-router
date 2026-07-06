// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Delivery guarantees — the Rust mirror of the proven-queueconn ABI tags.
//!
//! The tag values here MUST match the Idris2 ABI (`src/abi/ProvenQueue.idr`)
//! and proven-servers exactly, because they cross the FFI boundary as raw
//! bytes:
//!
//! ```text
//!   AtMostOnce  = 0
//!   AtLeastOnce = 1
//!   ExactlyOnce = 2
//! ```
//!
//! This is deliberately the *one* place in the Rust tree that names those
//! tags, so a future shared ABI crate has a single Rust definition to absorb
//! rather than several hand-synced copies.

use serde::{Deserialize, Serialize};

/// The delivery guarantee a target's transport provides for an event.
///
/// This is the exactly-once/at-least-once/at-most-once axis that the routing
/// invariants (`noDuplicateDispatch`) are conditioned on: the `LTE n 1` bound
/// only holds for transports that are at least `ExactlyOnce`, backed by the
/// Ephapax linear-token discipline on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryGuarantee {
    /// Fire-and-forget: the event may be dropped, never duplicated. Tag `0`.
    AtMostOnce,
    /// Retried until acknowledged: never dropped, may be duplicated. Tag `1`.
    AtLeastOnce,
    /// Delivered exactly once: never dropped, never duplicated. Tag `2`.
    ExactlyOnce,
}

impl DeliveryGuarantee {
    /// The C-ABI tag byte. MUST match `ProvenQueue.idr` and proven-servers.
    pub fn abi_tag(self) -> u8 {
        match self {
            Self::AtMostOnce => 0,
            Self::AtLeastOnce => 1,
            Self::ExactlyOnce => 2,
        }
    }

    /// Recover a guarantee from its C-ABI tag byte, or `None` if out of range.
    pub fn from_abi_tag(tag: u8) -> Option<Self> {
        match tag {
            0 => Some(Self::AtMostOnce),
            1 => Some(Self::AtLeastOnce),
            2 => Some(Self::ExactlyOnce),
            _ => None,
        }
    }

    /// Whether this guarantee forbids duplicate delivery (the upper bound the
    /// `noDuplicateDispatch` proof establishes). True only for `ExactlyOnce`.
    pub fn forbids_duplicates(self) -> bool {
        matches!(self, Self::ExactlyOnce)
    }

    /// Whether this guarantee forbids silent drops (the lower bound the
    /// `noEventLoss` proof establishes). True for at-least/exactly-once.
    pub fn forbids_drops(self) -> bool {
        matches!(self, Self::AtLeastOnce | Self::ExactlyOnce)
    }
}

impl Default for DeliveryGuarantee {
    /// HAR defaults to the strongest guarantee — the router's whole point is
    /// no silent drops and no duplicates.
    fn default() -> Self {
        Self::ExactlyOnce
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abi_tags_round_trip_and_match_the_idris_abi() {
        for g in [
            DeliveryGuarantee::AtMostOnce,
            DeliveryGuarantee::AtLeastOnce,
            DeliveryGuarantee::ExactlyOnce,
        ] {
            assert_eq!(DeliveryGuarantee::from_abi_tag(g.abi_tag()), Some(g));
        }
        // Pin the exact wire values — a change here is an ABI break.
        assert_eq!(DeliveryGuarantee::AtMostOnce.abi_tag(), 0);
        assert_eq!(DeliveryGuarantee::AtLeastOnce.abi_tag(), 1);
        assert_eq!(DeliveryGuarantee::ExactlyOnce.abi_tag(), 2);
        assert_eq!(DeliveryGuarantee::from_abi_tag(3), None);
    }

    #[test]
    fn exactly_once_is_the_strong_default() {
        assert_eq!(DeliveryGuarantee::default(), DeliveryGuarantee::ExactlyOnce);
        assert!(DeliveryGuarantee::default().forbids_duplicates());
        assert!(DeliveryGuarantee::default().forbids_drops());
        assert!(!DeliveryGuarantee::AtMostOnce.forbids_drops());
        assert!(!DeliveryGuarantee::AtLeastOnce.forbids_duplicates());
    }
}
