// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Shared queue ABI — the Rust binding of `abi/SHARED-QUEUE-ABI.adoc`.
//!
//! This module is a **binding of the normative spec**, not an independent
//! declaration. Every tag value here is pinned by, and MUST match,
//! `abi/SHARED-QUEUE-ABI.adoc` (and therefore the Idris2 binding in
//! `src/abi/ProvenQueue.idr` and proven-queueconn upstream). The conformance
//! tests at the bottom fail if any value drifts.
//!
//! [`DeliveryGuarantee`] — the tag that the routing invariants are conditioned
//! on — lives in [`crate::guarantee`] and is re-exported here so the whole ABI
//! tag surface is reachable from one place.

pub use crate::guarantee::DeliveryGuarantee;

/// ABI version carried in-band on every envelope and receipt. A change to any
/// tag value, the envelope/receipt layout, or the queue-naming scheme is a
/// breaking change and MUST increment this.
pub const ABI_VERSION: u32 = 1;

/// Maximum envelope payload size in bytes (1 MiB), matching proven-queueconn.
pub const MAX_EVENT_SIZE: usize = 1_048_576;

/// Default consumer prefetch count.
pub const DEFAULT_PREFETCH: u32 = 10;

/// Default acknowledgement timeout in seconds.
pub const ACK_TIMEOUT_SECS: u32 = 30;

/// Macro: define a `u8`-tagged ABI enum with `to_abi_tag` / `from_abi_tag`,
/// keeping the byte values in one obvious column so drift is easy to spot.
macro_rules! abi_enum {
    (
        $(#[$meta:meta])*
        $name:ident { $( $variant:ident = $tag:literal ),+ $(,)? }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, ::serde::Serialize, ::serde::Deserialize)]
        #[serde(rename_all = "snake_case")]
        pub enum $name {
            $( #[allow(missing_docs)] $variant ),+
        }

        impl $name {
            /// The C-ABI tag byte. MUST match `abi/SHARED-QUEUE-ABI.adoc`.
            pub fn to_abi_tag(self) -> u8 {
                match self { $( Self::$variant => $tag ),+ }
            }

            /// Recover from a tag byte, or `None` if out of range.
            pub fn from_abi_tag(tag: u8) -> Option<Self> {
                match tag { $( $tag => Some(Self::$variant), )+ _ => None }
            }
        }
    };
}

abi_enum! {
    /// Operations against a target's queue. Tags per `SHARED-QUEUE-ABI.adoc`.
    QueueOp {
        Publish = 0,
        Subscribe = 1,
        Acknowledge = 2,
        Reject = 3,
        Peek = 4,
        Purge = 5,
    }
}

abi_enum! {
    /// Connection lifecycle to a target. Tags per `SHARED-QUEUE-ABI.adoc`.
    QueueState {
        Disconnected = 0,
        Connected = 1,
        Consuming = 2,
        Producing = 3,
        Failed = 4,
    }
}

abi_enum! {
    /// A routed event's lifecycle. Tags per `SHARED-QUEUE-ABI.adoc`.
    MessageState {
        Pending = 0,
        Delivered = 1,
        Acknowledged = 2,
        Rejected = 3,
        DeadLettered = 4,
        Expired = 5,
    }
}

abi_enum! {
    /// Dispatch error categories. Tags per `SHARED-QUEUE-ABI.adoc`, which
    /// tracks the canonical proven-queueconn layout: tag `0` is the `NoError`
    /// success sentinel (proven-queueconn's `NONE`, returned across the C ABI
    /// on success), and the seven real errors are `1..=7`.
    QueueError {
        NoError = 0,
        ConnectionLost = 1,
        QueueNotFound = 2,
        MessageTooLarge = 3,
        QuotaExceeded = 4,
        AckTimeout = 5,
        Unauthorized = 6,
        SerializationError = 7,
    }
}

/// The canonical dispatch (producer → target) queue name for a target.
pub fn inbound_queue(target_id: &str) -> String {
    format!("har.{target_id}.inbound")
}

/// The canonical receipt (target → producer) queue name for a target.
pub fn receipt_queue(target_id: &str) -> String {
    format!("har.{target_id}.receipts")
}

#[cfg(test)]
mod conformance {
    use super::*;

    /// Every tag value pinned to `abi/SHARED-QUEUE-ABI.adoc`. If this test is
    /// edited to change a value, the spec and the Idris binding MUST change too
    /// and `ABI_VERSION` MUST bump.
    #[test]
    fn tag_values_match_the_spec() {
        assert_eq!(ABI_VERSION, 1);

        assert_eq!(DeliveryGuarantee::AtMostOnce.abi_tag(), 0);
        assert_eq!(DeliveryGuarantee::AtLeastOnce.abi_tag(), 1);
        assert_eq!(DeliveryGuarantee::ExactlyOnce.abi_tag(), 2);

        assert_eq!(QueueOp::Publish.to_abi_tag(), 0);
        assert_eq!(QueueOp::Purge.to_abi_tag(), 5);

        assert_eq!(QueueState::Disconnected.to_abi_tag(), 0);
        assert_eq!(QueueState::Failed.to_abi_tag(), 4);

        assert_eq!(MessageState::Pending.to_abi_tag(), 0);
        assert_eq!(MessageState::Acknowledged.to_abi_tag(), 2);
        assert_eq!(MessageState::DeadLettered.to_abi_tag(), 4);
        assert_eq!(MessageState::Expired.to_abi_tag(), 5);

        assert_eq!(QueueError::NoError.to_abi_tag(), 0);
        assert_eq!(QueueError::ConnectionLost.to_abi_tag(), 1);
        assert_eq!(QueueError::SerializationError.to_abi_tag(), 7);

        assert_eq!(MAX_EVENT_SIZE, 1_048_576);
        assert_eq!(DEFAULT_PREFETCH, 10);
        assert_eq!(ACK_TIMEOUT_SECS, 30);
    }

    #[test]
    fn all_tags_round_trip_and_reject_out_of_range() {
        for tag in 0u8..6 {
            assert_eq!(
                QueueOp::from_abi_tag(tag).map(|v| v.to_abi_tag()),
                Some(tag)
            );
        }
        assert_eq!(QueueOp::from_abi_tag(6), None);

        for tag in 0u8..5 {
            assert_eq!(
                QueueState::from_abi_tag(tag).map(|v| v.to_abi_tag()),
                Some(tag)
            );
        }
        assert_eq!(QueueState::from_abi_tag(5), None);

        for tag in 0u8..6 {
            assert_eq!(
                MessageState::from_abi_tag(tag).map(|v| v.to_abi_tag()),
                Some(tag)
            );
        }
        assert_eq!(MessageState::from_abi_tag(6), None);

        for tag in 0u8..8 {
            assert_eq!(
                QueueError::from_abi_tag(tag).map(|v| v.to_abi_tag()),
                Some(tag)
            );
        }
        assert_eq!(QueueError::from_abi_tag(8), None);
    }

    #[test]
    fn queue_names_follow_the_canonical_scheme() {
        assert_eq!(inbound_queue("rpa-elysium"), "har.rpa-elysium.inbound");
        assert_eq!(receipt_queue("rpa-elysium"), "har.rpa-elysium.receipts");
    }
}
