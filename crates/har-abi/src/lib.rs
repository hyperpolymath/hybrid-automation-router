// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! # har-abi — the shared queue ABI
//!
//! Self-contained binding of the normative spec `abi/SHARED-QUEUE-ABI.adoc`
//! (`abi_version = 1`), designed to be **vendored by both HAR and rpa-elysium**
//! so the two sides bind to one source instead of hand-syncing separate copies.
//!
//! This crate deliberately has no dependency on the rest of HAR — it is the
//! "separate shared artifact" (owner decision, 2026-07-06): the *generic*
//! proven-queueconn tags stay canonical upstream in proven-queueconn, and the
//! *HAR↔rpa-specific* codec + queue-naming live here, out of the generic
//! connector.
//!
//! Contents:
//! - the five proven-queueconn tag enums ([`DeliveryGuarantee`], [`QueueOp`],
//!   [`QueueState`], [`MessageState`], [`QueueError`]), tag values pinned to the
//!   spec and conformance-tested;
//! - the wire codec ([`RoutedEnvelope`], [`RoutedReceipt`]);
//! - the canonical queue-naming scheme ([`inbound_queue`], [`receipt_queue`]).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

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

// ───────────────────────────── Delivery guarantee ──────────────────────────

/// The delivery guarantee a target's transport provides for an event.
///
/// This is the exactly-once/at-least-once/at-most-once axis the routing
/// invariants are conditioned on: `noDuplicateDispatch`'s `LTE n 1` bound only
/// holds at `ExactlyOnce`, backed by the Ephapax linear-token discipline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryGuarantee {
    /// Fire-and-forget: may be dropped, never duplicated. Tag `0`.
    AtMostOnce,
    /// Retried until acknowledged: never dropped, may be duplicated. Tag `1`.
    AtLeastOnce,
    /// Delivered exactly once: never dropped, never duplicated. Tag `2`.
    ExactlyOnce,
}

impl DeliveryGuarantee {
    /// The C-ABI tag byte. MUST match the spec and proven-queueconn.
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

    /// Whether this guarantee forbids duplicate delivery (`noDuplicateDispatch`
    /// upper bound). True only for `ExactlyOnce`.
    pub fn forbids_duplicates(self) -> bool {
        matches!(self, Self::ExactlyOnce)
    }

    /// Whether this guarantee forbids silent drops (`noEventLoss` lower bound).
    /// True for at-least/exactly-once.
    pub fn forbids_drops(self) -> bool {
        matches!(self, Self::AtLeastOnce | Self::ExactlyOnce)
    }
}

impl Default for DeliveryGuarantee {
    /// HAR defaults to the strongest guarantee — no silent drops, no duplicates.
    fn default() -> Self {
        Self::ExactlyOnce
    }
}

// ───────────────────────────── Tagged ABI enums ────────────────────────────

/// Define a `u8`-tagged ABI enum with `to_abi_tag` / `from_abi_tag`, keeping
/// the byte values in one obvious column so drift is easy to spot.
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
    /// Dispatch error categories. Mirrors the canonical proven-queueconn C ABI:
    /// tag `0` is the `NoError` success sentinel (proven-queueconn's `NONE`),
    /// and the seven real errors are `1..=7`.
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

// ───────────────────────────── Queue naming ────────────────────────────────

/// The canonical dispatch (producer → target) queue name for a target.
pub fn inbound_queue(target_id: &str) -> String {
    format!("har.{target_id}.inbound")
}

/// The canonical receipt (target → producer) queue name for a target.
pub fn receipt_queue(target_id: &str) -> String {
    format!("har.{target_id}.receipts")
}

// ───────────────────────────── Wire codec ──────────────────────────────────

/// Errors from encoding/decoding or validating wire messages.
#[derive(Debug, thiserror::Error)]
pub enum AbiError {
    /// The message's `abi_version` did not equal [`ABI_VERSION`].
    #[error("ABI version mismatch: got {got}, expected {ABI_VERSION}")]
    VersionMismatch {
        /// The version seen on the wire.
        got: u32,
    },
    /// The payload exceeded [`MAX_EVENT_SIZE`].
    #[error("payload too large: {got} bytes > {MAX_EVENT_SIZE}")]
    PayloadTooLarge {
        /// The oversized payload length.
        got: usize,
    },
    /// JSON (de)serialisation failed.
    #[error("codec error: {0}")]
    Codec(#[from] serde_json::Error),
}

/// base64 (de)serialisation for the opaque payload, so the Rust side works in
/// raw bytes while the wire form is a base64 string per the spec.
mod b64 {
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = String::deserialize(d)?;
        STANDARD.decode(s).map_err(serde::de::Error::custom)
    }
}

/// The producer→consumer envelope (`RoutedEnvelope` in the spec). Carries an
/// opaque payload plus enough structured headers for routing/observability;
/// consumers read the headers they need and treat `payload` as opaque bytes
/// described by `content_type`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoutedEnvelope {
    /// MUST equal [`ABI_VERSION`]; peers reject a mismatch.
    pub abi_version: u32,
    /// Stable event id (the unit the routing invariants track).
    pub event_id: String,
    /// Routing category (e.g. `filesystem`).
    pub category: String,
    /// Priority: `low`=0, `normal`=1, `high`=2, `critical`=3.
    pub priority: u8,
    /// [`DeliveryGuarantee`] tag byte.
    pub guarantee: u8,
    /// MIME type of `payload` (e.g. `application/json`).
    pub content_type: String,
    /// Opaque body (base64 on the wire); ≤ [`MAX_EVENT_SIZE`].
    #[serde(with = "b64")]
    pub payload: Vec<u8>,
    /// Structured metadata (reserved keys: `tags`, `target_hint`,
    /// `required_capabilities`, `source`).
    pub headers: BTreeMap<String, String>,
    /// Producer timestamp (RFC 3339).
    pub created_at: String,
}

impl RoutedEnvelope {
    /// Start an envelope at the current [`ABI_VERSION`] with an opaque payload.
    pub fn new(
        event_id: impl Into<String>,
        category: impl Into<String>,
        priority: u8,
        guarantee: DeliveryGuarantee,
        content_type: impl Into<String>,
        payload: Vec<u8>,
        created_at: impl Into<String>,
    ) -> Self {
        Self {
            abi_version: ABI_VERSION,
            event_id: event_id.into(),
            category: category.into(),
            priority,
            guarantee: guarantee.abi_tag(),
            content_type: content_type.into(),
            payload,
            headers: BTreeMap::new(),
            created_at: created_at.into(),
        }
    }

    /// Set a header key, returning `self` for chaining.
    pub fn with_header(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.insert(key.into(), value.into());
        self
    }

    /// Validate the envelope: correct `abi_version` and in-bounds payload.
    pub fn validate(&self) -> Result<(), AbiError> {
        if self.abi_version != ABI_VERSION {
            return Err(AbiError::VersionMismatch {
                got: self.abi_version,
            });
        }
        if self.payload.len() > MAX_EVENT_SIZE {
            return Err(AbiError::PayloadTooLarge {
                got: self.payload.len(),
            });
        }
        Ok(())
    }

    /// The declared [`DeliveryGuarantee`], if the tag is in range.
    pub fn guarantee(&self) -> Option<DeliveryGuarantee> {
        DeliveryGuarantee::from_abi_tag(self.guarantee)
    }

    /// Encode to canonical JSON bytes after validating.
    pub fn encode(&self) -> Result<Vec<u8>, AbiError> {
        self.validate()?;
        Ok(serde_json::to_vec(self)?)
    }

    /// Decode from JSON bytes and validate (rejects version/size violations).
    pub fn decode(bytes: &[u8]) -> Result<Self, AbiError> {
        let env: Self = serde_json::from_slice(bytes)?;
        env.validate()?;
        Ok(env)
    }
}

/// The consumer→producer receipt (`DeliveryReceipt` in the spec; named
/// `RoutedReceipt` here to avoid colliding with har-dispatch's internal
/// `DeliveryReceipt`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoutedReceipt {
    /// MUST equal [`ABI_VERSION`].
    pub abi_version: u32,
    /// The `event_id` being reported on.
    pub event_id: String,
    /// The consuming target.
    pub target_id: String,
    /// [`MessageState`] tag (`2` Acknowledged, `3` Rejected, `4` DeadLettered…).
    pub outcome: u8,
    /// Human-readable note (reject reason, etc.).
    pub detail: String,
    /// Consumer timestamp (RFC 3339).
    pub acked_at: String,
}

impl RoutedReceipt {
    /// Build a receipt at the current [`ABI_VERSION`].
    pub fn new(
        event_id: impl Into<String>,
        target_id: impl Into<String>,
        outcome: MessageState,
        detail: impl Into<String>,
        acked_at: impl Into<String>,
    ) -> Self {
        Self {
            abi_version: ABI_VERSION,
            event_id: event_id.into(),
            target_id: target_id.into(),
            outcome: outcome.to_abi_tag(),
            detail: detail.into(),
            acked_at: acked_at.into(),
        }
    }

    /// Validate the `abi_version`.
    pub fn validate(&self) -> Result<(), AbiError> {
        if self.abi_version != ABI_VERSION {
            return Err(AbiError::VersionMismatch {
                got: self.abi_version,
            });
        }
        Ok(())
    }

    /// The reported [`MessageState`], if the tag is in range.
    pub fn outcome(&self) -> Option<MessageState> {
        MessageState::from_abi_tag(self.outcome)
    }

    /// Encode to JSON bytes after validating.
    pub fn encode(&self) -> Result<Vec<u8>, AbiError> {
        self.validate()?;
        Ok(serde_json::to_vec(self)?)
    }

    /// Decode from JSON bytes and validate.
    pub fn decode(bytes: &[u8]) -> Result<Self, AbiError> {
        let r: Self = serde_json::from_slice(bytes)?;
        r.validate()?;
        Ok(r)
    }
}

#[cfg(test)]
mod conformance {
    use super::*;

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
        assert_eq!(MessageState::Expired.to_abi_tag(), 5);

        // QueueError is 0=NoError sentinel + 1..7 (canonical proven-queueconn).
        assert_eq!(QueueError::NoError.to_abi_tag(), 0);
        assert_eq!(QueueError::ConnectionLost.to_abi_tag(), 1);
        assert_eq!(QueueError::SerializationError.to_abi_tag(), 7);

        assert_eq!(MAX_EVENT_SIZE, 1_048_576);
        assert_eq!(DEFAULT_PREFETCH, 10);
        assert_eq!(ACK_TIMEOUT_SECS, 30);
    }

    #[test]
    fn all_tags_round_trip_and_reject_out_of_range() {
        for tag in 0u8..3 {
            assert_eq!(
                DeliveryGuarantee::from_abi_tag(tag).map(|v| v.abi_tag()),
                Some(tag)
            );
        }
        assert_eq!(DeliveryGuarantee::from_abi_tag(3), None);

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

#[cfg(test)]
mod codec {
    use super::*;

    fn sample() -> RoutedEnvelope {
        RoutedEnvelope::new(
            "evt-1",
            "filesystem",
            1,
            DeliveryGuarantee::ExactlyOnce,
            "application/json",
            br#"{"path":"/tmp/x"}"#.to_vec(),
            "2026-07-06T00:00:00Z",
        )
        .with_header("target_hint", "rpa-elysium")
        .with_header("tags", "urgent,fs")
    }

    #[test]
    fn envelope_round_trips_through_json_with_base64_payload() {
        let env = sample();
        let bytes = env.encode().unwrap();

        // Payload is base64 on the wire, not a JSON number array.
        let text = String::from_utf8(bytes.clone()).unwrap();
        assert!(
            text.contains("\"payload\":\""),
            "payload must be a base64 string"
        );

        let back = RoutedEnvelope::decode(&bytes).unwrap();
        assert_eq!(back, env);
        assert_eq!(back.payload, br#"{"path":"/tmp/x"}"#.to_vec());
        assert_eq!(back.guarantee(), Some(DeliveryGuarantee::ExactlyOnce));
    }

    #[test]
    fn decode_rejects_version_mismatch() {
        let mut env = sample();
        env.abi_version = 2;
        let bytes = serde_json::to_vec(&env).unwrap();
        assert!(matches!(
            RoutedEnvelope::decode(&bytes),
            Err(AbiError::VersionMismatch { got: 2 })
        ));
    }

    #[test]
    fn encode_rejects_oversized_payload() {
        let mut env = sample();
        env.payload = vec![0u8; MAX_EVENT_SIZE + 1];
        assert!(matches!(
            env.encode(),
            Err(AbiError::PayloadTooLarge { .. })
        ));
    }

    #[test]
    fn receipt_round_trips() {
        let r = RoutedReceipt::new(
            "evt-1",
            "rpa-elysium",
            MessageState::Acknowledged,
            "ok",
            "2026-07-06T00:00:01Z",
        );
        let bytes = r.encode().unwrap();
        let back = RoutedReceipt::decode(&bytes).unwrap();
        assert_eq!(back, r);
        assert_eq!(back.outcome(), Some(MessageState::Acknowledged));
    }
}
