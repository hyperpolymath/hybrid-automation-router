// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! NATS-backed transport — the first *real* (non-in-memory) [`TargetTransport`].
//!
//! This is the start of the broker connector (owner decision, 2026-07-06): a
//! transport that encodes a shared-ABI [`RoutedEnvelope`](har_core::abi::RoutedEnvelope)
//! and publishes it to the canonical `har.<target_id>.inbound` subject.
//!
//! NATS was chosen as a Rust-native, FOSS/CNCF broker (via `async-nats`), and
//! it stays swappable: this is one impl behind the broker-agnostic
//! [`TargetTransport`] trait, so an AMQP/other impl is a sibling, not a rewrite.
//!
//! ## Delivery guarantee mapping
//! - [`AtMostOnce`](har_core::DeliveryGuarantee::AtMostOnce) → **core NATS**
//!   publish (fire-and-forget).
//! - [`AtLeastOnce`](har_core::DeliveryGuarantee::AtLeastOnce) /
//!   [`ExactlyOnce`](har_core::DeliveryGuarantee::ExactlyOnce) → **JetStream**
//!   publish with a server ack (durable, acknowledged). True end-to-end
//!   exactly-once additionally relies on consumer-side idempotency +
//!   deduplication, which is rpa-elysium's side of the contract.
//!
//! ## Testing
//! Gated behind the `nats` feature so the default build/CI need neither the
//! dependency tree nor a server. The live round-trip test is `#[ignore]` and
//! reads `NATS_URL`; run it against a real server with
//! `cargo test -p har-dispatch --features nats -- --ignored`.

use crate::{DeliveryReceipt, TargetTransport};
use async_trait::async_trait;
use chrono::Utc;
use har_core::{abi, AutomationEvent, DeliveryGuarantee, Error, Result};

/// A NATS-backed [`TargetTransport`] that publishes shared-ABI envelopes to a
/// target's canonical inbound subject.
pub struct NatsTransport {
    client: async_nats::Client,
    target_id: String,
    guarantee: DeliveryGuarantee,
    /// Whether to use JetStream (durable, acknowledged) publishing. Derived
    /// from the guarantee: true for at-least/exactly-once.
    use_jetstream: bool,
}

impl NatsTransport {
    /// Connect to a NATS server and bind this transport to `target_id` with the
    /// given delivery `guarantee`. Publishing goes to `inbound_queue(target_id)`.
    pub async fn connect(
        url: impl AsRef<str>,
        target_id: impl Into<String>,
        guarantee: DeliveryGuarantee,
    ) -> Result<Self> {
        let client =
            async_nats::connect(url.as_ref())
                .await
                .map_err(|e| Error::TargetUnavailable {
                    target: "nats".into(),
                    reason: format!("connect: {e}"),
                })?;
        Ok(Self {
            client,
            target_id: target_id.into(),
            guarantee,
            use_jetstream: guarantee.forbids_drops(),
        })
    }

    /// The canonical inbound subject this transport publishes to.
    pub fn subject(&self) -> String {
        abi::inbound_queue(&self.target_id)
    }

    fn unavailable(&self, stage: &str, e: impl std::fmt::Display) -> Error {
        Error::TargetUnavailable {
            target: self.target_id.clone(),
            reason: format!("{stage}: {e}"),
        }
    }
}

#[async_trait]
impl TargetTransport for NatsTransport {
    async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt> {
        // Encode the event as a shared-ABI RoutedEnvelope (validated).
        let envelope = event.to_envelope(self.guarantee)?;
        let bytes = envelope
            .encode()
            .map_err(|e| Error::Routing(format!("ABI encode: {e}")))?;
        let subject = self.subject();
        let start = std::time::Instant::now();

        let acknowledged = if self.use_jetstream {
            // Durable publish + wait for the server ack.
            let js = async_nats::jetstream::new(self.client.clone());
            let ack_future = js
                .publish(subject, bytes.into())
                .await
                .map_err(|e| self.unavailable("publish", e))?;
            ack_future.await.map_err(|e| self.unavailable("ack", e))?;
            true
        } else {
            // Core NATS: fire-and-forget, flush to surface connection errors.
            self.client
                .publish(subject, bytes.into())
                .await
                .map_err(|e| self.unavailable("publish", e))?;
            self.client
                .flush()
                .await
                .map_err(|e| self.unavailable("flush", e))?;
            false
        };

        Ok(DeliveryReceipt {
            event_id: event.id.clone(),
            target_id: self.target_id.clone(),
            delivered_at: Utc::now(),
            latency_us: start.elapsed().as_micros() as u64,
            acknowledged,
        })
    }

    fn is_connected(&self) -> bool {
        matches!(
            self.client.connection_state(),
            async_nats::connection::State::Connected
        )
    }

    fn name(&self) -> &str {
        &self.target_id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use har_core::EventSource;

    /// Live publish smoke test against a real NATS server. Ignored by default;
    /// run with a server up: `NATS_URL=nats://127.0.0.1:4222 \
    ///   cargo test -p har-dispatch --features nats -- --ignored`.
    #[tokio::test]
    #[ignore = "requires a running NATS server (set NATS_URL)"]
    async fn live_publish_smoke() {
        let url = std::env::var("NATS_URL").unwrap_or_else(|_| "nats://127.0.0.1:4222".into());
        let transport = NatsTransport::connect(&url, "rpa-elysium", DeliveryGuarantee::AtMostOnce)
            .await
            .expect("connect");
        assert!(transport.is_connected());
        assert_eq!(transport.subject(), "har.rpa-elysium.inbound");

        let event = AutomationEvent::new(
            EventSource::Filesystem {
                path: "/tmp/x".into(),
            },
            "filesystem",
        );
        let receipt = transport.deliver(&event).await.expect("deliver");
        assert_eq!(receipt.target_id, "rpa-elysium");
        assert_eq!(receipt.event_id, event.id);
    }
}
