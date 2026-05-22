// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! HAR Dispatch — Event dispatch to automation targets
//!
//! This crate bridges HAR routing decisions to actual target delivery.
//! It implements the proven-queueconn dispatch pattern: HAR produces
//! events, targets (like rpa-elysium) consume them.
//!
//! # Dispatch Flow
//!
//! ```text
//! RouteDecision ──→ Dispatcher ──→ TargetTransport ──→ Target
//!                       │
//!                       ├── Retry logic
//!                       ├── Dead-letter handling
//!                       └── Delivery confirmation
//! ```

#![forbid(unsafe_code)]
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use har_core::{AutomationEvent, Error, Result, RouteDecision};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};

/// Transport layer for delivering events to a target
#[async_trait]
pub trait TargetTransport: Send + Sync {
    /// Deliver an event to the target
    async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt>;

    /// Check if the transport is connected
    fn is_connected(&self) -> bool;

    /// Transport name (for logging)
    fn name(&self) -> &str;
}

/// Receipt confirming event delivery
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeliveryReceipt {
    /// Event that was delivered
    pub event_id: String,
    /// Target that received the event
    pub target_id: String,
    /// When delivery was confirmed
    pub delivered_at: DateTime<Utc>,
    /// Delivery latency in microseconds
    pub latency_us: u64,
    /// Whether the target acknowledged processing
    pub acknowledged: bool,
}

/// What happens to events that can't be delivered
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeadLetter {
    /// Event that could not be delivered
    pub event_id: String,
    /// Target that was supposed to receive it
    pub target_id: String,
    /// Reason for failure
    pub reason: String,
    /// When the event was dead-lettered
    pub dead_lettered_at: DateTime<Utc>,
    /// Number of delivery attempts made
    pub attempts: u32,
}

/// Configuration for dispatch retry behaviour
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetryPolicy {
    /// Maximum number of delivery attempts
    pub max_attempts: u32,
    /// Base delay between retries in milliseconds
    pub base_delay_ms: u64,
    /// Whether to use exponential backoff
    pub exponential_backoff: bool,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_delay_ms: 1000,
            exponential_backoff: true,
        }
    }
}

/// In-memory transport for testing and in-process targets
pub struct InMemoryTransport {
    name: String,
    connected: bool,
    delivered: Arc<Mutex<Vec<AutomationEvent>>>,
}

impl InMemoryTransport {
    /// Create a connected in-memory transport
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            connected: true,
            delivered: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Get all delivered events (for testing)
    pub async fn delivered_events(&self) -> Vec<AutomationEvent> {
        self.delivered.lock().await.clone()
    }

    /// Simulate disconnection
    pub fn disconnect(&mut self) {
        self.connected = false;
    }
}

#[async_trait]
impl TargetTransport for InMemoryTransport {
    async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt> {
        if !self.connected {
            return Err(Error::TargetUnavailable {
                target: self.name.clone(),
                reason: "Transport disconnected".into(),
            });
        }

        let start = std::time::Instant::now();
        self.delivered.lock().await.push(event.clone());
        let latency = start.elapsed().as_micros() as u64;

        Ok(DeliveryReceipt {
            event_id: event.id.clone(),
            target_id: self.name.clone(),
            delivered_at: Utc::now(),
            latency_us: latency,
            acknowledged: true,
        })
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    fn name(&self) -> &str {
        &self.name
    }
}

/// The main dispatcher that delivers routed events to targets
pub struct Dispatcher {
    transports: HashMap<String, Arc<dyn TargetTransport>>,
    retry_policy: RetryPolicy,
    dead_letters: Arc<Mutex<Vec<DeadLetter>>>,
    receipts: Arc<Mutex<Vec<DeliveryReceipt>>>,
}

impl Dispatcher {
    /// Create a new dispatcher with default retry policy
    pub fn new() -> Self {
        Self {
            transports: HashMap::new(),
            retry_policy: RetryPolicy::default(),
            dead_letters: Arc::new(Mutex::new(Vec::new())),
            receipts: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Set the retry policy
    pub fn with_retry_policy(mut self, policy: RetryPolicy) -> Self {
        self.retry_policy = policy;
        self
    }

    /// Register a transport for a target
    pub fn register_transport(
        &mut self,
        target_id: impl Into<String>,
        transport: Arc<dyn TargetTransport>,
    ) {
        let id = target_id.into();
        info!(
            "Dispatcher: registered transport '{}' for target '{}'",
            transport.name(),
            id
        );
        self.transports.insert(id, transport);
    }

    /// Dispatch a routed event based on the routing decision
    pub async fn dispatch(
        &self,
        decision: &RouteDecision,
        event: &AutomationEvent,
    ) -> Result<DeliveryReceipt> {
        let transport =
            self.transports
                .get(&decision.target_id)
                .ok_or_else(|| Error::TargetUnavailable {
                    target: decision.target_id.clone(),
                    reason: "No transport registered".into(),
                })?;

        debug!(
            "Dispatching event {} to target {} via {}",
            event.id,
            decision.target_id,
            transport.name()
        );

        // Attempt delivery with retry
        let mut last_error = None;
        for attempt in 1..=self.retry_policy.max_attempts {
            match transport.deliver(event).await {
                Ok(receipt) => {
                    info!(
                        "Delivered event {} to {} (attempt {}, {}µs)",
                        event.id, decision.target_id, attempt, receipt.latency_us
                    );
                    self.receipts.lock().await.push(receipt.clone());
                    return Ok(receipt);
                }
                Err(e) => {
                    warn!(
                        "Delivery attempt {}/{} failed for event {} → {}: {}",
                        attempt, self.retry_policy.max_attempts, event.id, decision.target_id, e
                    );
                    last_error = Some(e);

                    if attempt < self.retry_policy.max_attempts {
                        let delay = if self.retry_policy.exponential_backoff {
                            self.retry_policy.base_delay_ms * 2u64.pow(attempt - 1)
                        } else {
                            self.retry_policy.base_delay_ms
                        };
                        tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
                    }
                }
            }
        }

        // All attempts exhausted — dead-letter
        let dead_letter = DeadLetter {
            event_id: event.id.clone(),
            target_id: decision.target_id.clone(),
            reason: last_error
                .as_ref()
                .map(|e| e.to_string())
                .unwrap_or_else(|| "Unknown error".into()),
            dead_lettered_at: Utc::now(),
            attempts: self.retry_policy.max_attempts,
        };

        error!(
            "Dead-lettered event {} after {} attempts: {}",
            event.id, self.retry_policy.max_attempts, dead_letter.reason
        );

        self.dead_letters.lock().await.push(dead_letter);

        Err(last_error.unwrap_or_else(|| Error::Routing("All delivery attempts failed".into())))
    }

    /// Get all dead-lettered events
    pub async fn dead_letters(&self) -> Vec<DeadLetter> {
        self.dead_letters.lock().await.clone()
    }

    /// Get all delivery receipts
    pub async fn receipts(&self) -> Vec<DeliveryReceipt> {
        self.receipts.lock().await.clone()
    }

    /// Number of registered transports
    pub fn transport_count(&self) -> usize {
        self.transports.len()
    }
}

impl Default for Dispatcher {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use har_core::EventSource;

    fn test_event() -> AutomationEvent {
        AutomationEvent::new(
            EventSource::Filesystem {
                path: "/tmp/test.txt".into(),
            },
            "filesystem",
        )
    }

    fn test_decision(event_id: &str) -> RouteDecision {
        RouteDecision::capability_match(event_id, "rpa-elysium", 1.0)
    }

    #[tokio::test]
    async fn test_dispatch_success() {
        let mut dispatcher = Dispatcher::new();
        let transport = Arc::new(InMemoryTransport::new("rpa-elysium"));
        dispatcher.register_transport("rpa-elysium", transport.clone());

        let event = test_event();
        let decision = test_decision(&event.id);

        let receipt = dispatcher.dispatch(&decision, &event).await.unwrap();
        assert_eq!(receipt.target_id, "rpa-elysium");
        assert!(receipt.acknowledged);
    }

    #[tokio::test]
    async fn test_dispatch_no_transport() {
        let dispatcher = Dispatcher::new();
        let event = test_event();
        let decision = test_decision(&event.id);

        let result = dispatcher.dispatch(&decision, &event).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_dispatch_disconnected_dead_letters() {
        let mut dispatcher = Dispatcher::new().with_retry_policy(RetryPolicy {
            max_attempts: 1,
            base_delay_ms: 0,
            exponential_backoff: false,
        });

        let mut transport = InMemoryTransport::new("rpa-elysium");
        transport.disconnect();
        dispatcher.register_transport("rpa-elysium", Arc::new(transport));

        let event = test_event();
        let decision = test_decision(&event.id);

        let result = dispatcher.dispatch(&decision, &event).await;
        assert!(result.is_err());

        let dead = dispatcher.dead_letters().await;
        assert_eq!(dead.len(), 1);
        assert_eq!(dead[0].target_id, "rpa-elysium");
    }

    #[tokio::test]
    async fn test_in_memory_transport() {
        let transport = InMemoryTransport::new("test");
        assert!(transport.is_connected());

        let event = test_event();
        let receipt = transport.deliver(&event).await.unwrap();
        assert!(receipt.acknowledged);

        let delivered = transport.delivered_events().await;
        assert_eq!(delivered.len(), 1);
    }

    #[tokio::test]
    async fn test_delivery_receipts_tracked() {
        let mut dispatcher = Dispatcher::new();
        dispatcher.register_transport("t1", Arc::new(InMemoryTransport::new("t1")));

        let event = test_event();
        let decision = RouteDecision::capability_match(&event.id, "t1", 1.0);

        dispatcher.dispatch(&decision, &event).await.unwrap();
        let receipts = dispatcher.receipts().await;
        assert_eq!(receipts.len(), 1);
    }
}
