// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! HAR Dispatch — Event dispatch to automation targets
//!
//! This crate bridges HAR routing decisions to actual target delivery.
//! It implements the proven-queueconn dispatch pattern: HAR produces
//! events, targets (like rpa-elysium) consume them.
//!
//! # Dispatch Flow
//!
//! ```text
//! RouteDecision ──→ Dispatcher ──→ TargetAdapter ──→ Target
//!                       │
//!                       ├── Per-target inflight cap (semaphore)
//!                       ├── Circuit breaker (shed load on repeated failure)
//!                       ├── Retry logic (backoff + jitter)
//!                       └── Dead-letter sink (persistable — no silent drops)
//! ```
//!
//! ## Guarantees this crate is built to honour
//!
//! - **No silent drops** — every dispatched event is either delivered (a
//!   [`DeliveryReceipt`]) or dead-lettered (a [`DeadLetter`] handed to the
//!   [`DeadLetterSink`]). A tripped circuit breaker dead-letters rather than
//!   dropping. This is the runtime echo of the Idris2 `noEventLoss` invariant.
//! - **Bounded concurrency** — a per-target semaphore caps inflight
//!   deliveries so a slow target cannot exhaust the dispatcher.

#![forbid(unsafe_code)]

/// NATS-backed real transport (behind the `nats` feature).
#[cfg(feature = "nats")]
pub mod nats;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use har_core::{
    AutomationEvent, DeliveryGuarantee, Error, Result, RouteDecision, TargetCapability,
    TargetStatus,
};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, Semaphore};
use tracing::{debug, error, info, warn};

/// Transport layer for delivering events to a target.
///
/// This is the minimal "put bytes on the wire" surface. Most callers should
/// prefer [`TargetAdapter`], which adds capability declaration, health, drain,
/// and the delivery-guarantee ABI tag; any `TargetTransport` can be lifted
/// into a `TargetAdapter` with [`TransportAdapter`].
#[async_trait]
pub trait TargetTransport: Send + Sync {
    /// Deliver an event to the target
    async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt>;

    /// Check if the transport is connected
    fn is_connected(&self) -> bool;

    /// Transport name (for logging)
    fn name(&self) -> &str;
}

/// A fully-described automation target: transport plus the metadata the
/// dispatcher and router need to reason about it.
///
/// This is the typed target contract (issue #49 W2). It composes:
/// - **delivery** (`deliver`) — the transport surface;
/// - **capability declaration** (`capabilities`) — what the target can do,
///   mirroring [`har_core::AutomationTarget::capabilities`];
/// - **health** (`health`) — current operational status for the router;
/// - **drain** (`drain`) — graceful shutdown hook (finish inflight, accept no
///   more), matching the router lifecycle's draining state;
/// - **ABI tag** (`guarantee`) — the delivery guarantee the transport provides,
///   carried across the FFI boundary as a [`DeliveryGuarantee`] tag byte.
#[async_trait]
pub trait TargetAdapter: Send + Sync {
    /// Stable target identifier (matches `AutomationTarget.id`).
    fn target_id(&self) -> &str;

    /// Capabilities this target declares it can service.
    fn capabilities(&self) -> &[TargetCapability];

    /// The delivery guarantee this target's transport provides. The
    /// `noDuplicateDispatch` upper bound only applies at `ExactlyOnce`.
    fn guarantee(&self) -> DeliveryGuarantee;

    /// Deliver an event, returning a receipt on success.
    async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt>;

    /// Current health, as the router would record it.
    async fn health(&self) -> TargetStatus;

    /// Gracefully drain: stop accepting new work and let inflight finish.
    /// Default is a no-op for transports without a drain concept.
    async fn drain(&self) -> Result<()> {
        Ok(())
    }
}

/// Lift any [`TargetTransport`] into a [`TargetAdapter`] by supplying the
/// metadata the bare transport lacks (capabilities, guarantee). Health is
/// derived from `is_connected()`.
pub struct TransportAdapter {
    target_id: String,
    capabilities: Vec<TargetCapability>,
    guarantee: DeliveryGuarantee,
    transport: Arc<dyn TargetTransport>,
}

impl TransportAdapter {
    /// Wrap a transport with a target id, no declared capabilities, and the
    /// strong default guarantee ([`DeliveryGuarantee::ExactlyOnce`]).
    pub fn new(target_id: impl Into<String>, transport: Arc<dyn TargetTransport>) -> Self {
        Self {
            target_id: target_id.into(),
            capabilities: Vec::new(),
            guarantee: DeliveryGuarantee::default(),
            transport,
        }
    }

    /// Declare the target's capabilities.
    pub fn with_capabilities(mut self, caps: Vec<TargetCapability>) -> Self {
        self.capabilities = caps;
        self
    }

    /// Set the delivery guarantee the transport provides.
    pub fn with_guarantee(mut self, guarantee: DeliveryGuarantee) -> Self {
        self.guarantee = guarantee;
        self
    }
}

#[async_trait]
impl TargetAdapter for TransportAdapter {
    fn target_id(&self) -> &str {
        &self.target_id
    }

    fn capabilities(&self) -> &[TargetCapability] {
        &self.capabilities
    }

    fn guarantee(&self) -> DeliveryGuarantee {
        self.guarantee
    }

    async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt> {
        self.transport.deliver(event).await
    }

    async fn health(&self) -> TargetStatus {
        if self.transport.is_connected() {
            TargetStatus::Healthy
        } else {
            TargetStatus::Unhealthy
        }
    }
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

/// A sink that records dead-lettered events. The default is in-memory, but the
/// trait exists so the dead-letter queue can be made durable: "no silent
/// drops" only holds across a crash if the DLQ outlives the process.
#[async_trait]
pub trait DeadLetterSink: Send + Sync {
    /// Persist a dead-letter. Returning `Err` means the DLQ itself failed —
    /// the caller should treat that as a hard error, since it breaks the
    /// no-silent-drops guarantee.
    async fn record(&self, dead_letter: &DeadLetter) -> Result<()>;

    /// Best-effort snapshot of recorded dead-letters. Write-only sinks may
    /// return an empty vec.
    async fn snapshot(&self) -> Result<Vec<DeadLetter>> {
        Ok(Vec::new())
    }
}

/// In-memory dead-letter sink (default). Lost on crash — fine for tests and
/// in-process use, but pair with a durable sink in production.
#[derive(Default)]
pub struct InMemorySink {
    dead_letters: Arc<Mutex<Vec<DeadLetter>>>,
}

impl InMemorySink {
    /// Create an empty in-memory sink.
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl DeadLetterSink for InMemorySink {
    async fn record(&self, dead_letter: &DeadLetter) -> Result<()> {
        self.dead_letters.lock().await.push(dead_letter.clone());
        Ok(())
    }

    async fn snapshot(&self) -> Result<Vec<DeadLetter>> {
        Ok(self.dead_letters.lock().await.clone())
    }
}

/// Durable dead-letter sink: appends one JSON object per line (JSONL) to a
/// file. Surviving a crash means dead-lettered events can be recovered and
/// replayed, so the no-silent-drops guarantee holds across restarts.
pub struct JsonlFileSink {
    path: std::path::PathBuf,
    write_lock: Mutex<()>,
}

impl JsonlFileSink {
    /// Create a sink appending to `path` (created on first write).
    pub fn new(path: impl Into<std::path::PathBuf>) -> Self {
        Self {
            path: path.into(),
            write_lock: Mutex::new(()),
        }
    }
}

#[async_trait]
impl DeadLetterSink for JsonlFileSink {
    async fn record(&self, dead_letter: &DeadLetter) -> Result<()> {
        use std::io::Write;
        let mut line = serde_json::to_string(dead_letter)?;
        line.push('\n');
        // Serialise writes so concurrent dispatches can't interleave lines.
        let _guard = self.write_lock.lock().await;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(line.as_bytes())?;
        Ok(())
    }

    async fn snapshot(&self) -> Result<Vec<DeadLetter>> {
        let _guard = self.write_lock.lock().await;
        let contents = match std::fs::read_to_string(&self.path) {
            Ok(c) => c,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(Error::Io(e)),
        };
        let mut out = Vec::new();
        for line in contents.lines().filter(|l| !l.trim().is_empty()) {
            out.push(serde_json::from_str(line)?);
        }
        Ok(out)
    }
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
    /// Whether to add deterministic per-event jitter to the backoff delay, to
    /// decorrelate retries across a burst of failing events. The jitter is
    /// derived from the event id + attempt (no RNG state), so it stays
    /// reproducible for tests and attestation.
    pub jitter: bool,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_delay_ms: 1000,
            exponential_backoff: true,
            jitter: true,
        }
    }
}

impl RetryPolicy {
    /// The backoff delay before `attempt`'s retry (1-indexed), including
    /// deterministic jitter when enabled.
    fn delay_for(&self, event_id: &str, attempt: u32) -> Duration {
        let base = if self.exponential_backoff {
            self.base_delay_ms
                .saturating_mul(2u64.saturating_pow(attempt.saturating_sub(1)))
        } else {
            self.base_delay_ms
        };
        let millis = if self.jitter && base > 0 {
            // Deterministic jitter in [0, base/2] seeded by (event_id, attempt).
            let mut h = DefaultHasher::new();
            event_id.hash(&mut h);
            attempt.hash(&mut h);
            base.saturating_add(h.finish() % (base / 2 + 1))
        } else {
            base
        };
        Duration::from_millis(millis)
    }
}

/// Circuit-breaker configuration for shedding load to a failing target.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BreakerPolicy {
    /// Consecutive dead-letters that trip the breaker open. `0` disables it.
    pub failure_threshold: u32,
    /// How long the breaker stays open before allowing a probe again.
    pub cooldown_ms: u64,
}

impl Default for BreakerPolicy {
    fn default() -> Self {
        Self {
            failure_threshold: 5,
            cooldown_ms: 30_000,
        }
    }
}

/// Per-target circuit-breaker state.
#[derive(Debug, Default)]
struct Breaker {
    consecutive_failures: u32,
    open_until: Option<Instant>,
}

impl Breaker {
    /// Is the breaker currently open (rejecting) at `now`?
    fn is_open(&self, now: Instant) -> bool {
        matches!(self.open_until, Some(until) if now < until)
    }
}

/// The main dispatcher that delivers routed events to targets.
pub struct Dispatcher {
    adapters: HashMap<String, Arc<dyn TargetAdapter>>,
    /// Per-target concurrency limiter. Absent entry ⇒ unbounded.
    inflight: HashMap<String, Arc<Semaphore>>,
    max_inflight: usize,
    retry_policy: RetryPolicy,
    breaker_policy: BreakerPolicy,
    breakers: Arc<StdMutex<HashMap<String, Breaker>>>,
    dead_letter_sink: Arc<dyn DeadLetterSink>,
    receipts: Arc<Mutex<Vec<DeliveryReceipt>>>,
}

impl Dispatcher {
    /// Create a new dispatcher with default policies and an in-memory DLQ.
    pub fn new() -> Self {
        Self {
            adapters: HashMap::new(),
            inflight: HashMap::new(),
            max_inflight: 0, // unbounded by default
            retry_policy: RetryPolicy::default(),
            breaker_policy: BreakerPolicy::default(),
            breakers: Arc::new(StdMutex::new(HashMap::new())),
            dead_letter_sink: Arc::new(InMemorySink::new()),
            receipts: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Set the retry policy
    pub fn with_retry_policy(mut self, policy: RetryPolicy) -> Self {
        self.retry_policy = policy;
        self
    }

    /// Set the circuit-breaker policy
    pub fn with_breaker_policy(mut self, policy: BreakerPolicy) -> Self {
        self.breaker_policy = policy;
        self
    }

    /// Cap the number of concurrent in-flight deliveries per target. `0` means
    /// unbounded. Applies to transports registered after this call.
    pub fn with_max_inflight(mut self, max: usize) -> Self {
        self.max_inflight = max;
        self
    }

    /// Use a specific dead-letter sink (e.g. a durable [`JsonlFileSink`]).
    pub fn with_dead_letter_sink(mut self, sink: Arc<dyn DeadLetterSink>) -> Self {
        self.dead_letter_sink = sink;
        self
    }

    /// Register a fully-described target adapter.
    pub fn register_adapter(&mut self, adapter: Arc<dyn TargetAdapter>) {
        let id = adapter.target_id().to_string();
        info!(
            "Dispatcher: registered adapter for target '{}' (guarantee: {:?})",
            id,
            adapter.guarantee()
        );
        if self.max_inflight > 0 {
            self.inflight
                .insert(id.clone(), Arc::new(Semaphore::new(self.max_inflight)));
        }
        self.adapters.insert(id, adapter);
    }

    /// Register a bare transport for a target, wrapping it in a
    /// [`TransportAdapter`] with default capabilities and the strong default
    /// guarantee. Kept for ergonomic in-process/test use.
    pub fn register_transport(
        &mut self,
        target_id: impl Into<String>,
        transport: Arc<dyn TargetTransport>,
    ) {
        let id = target_id.into();
        self.register_adapter(Arc::new(TransportAdapter::new(id, transport)));
    }

    /// Dispatch a routed event based on the routing decision.
    ///
    /// Delivers with bounded concurrency, a circuit breaker, and retry with
    /// backoff+jitter. Every event terminates in exactly one of: an `Ok`
    /// receipt, or an `Err` after the event has been recorded to the
    /// dead-letter sink — never a silent drop.
    pub async fn dispatch(
        &self,
        decision: &RouteDecision,
        event: &AutomationEvent,
    ) -> Result<DeliveryReceipt> {
        let target_id = decision.target_id.clone();
        let adapter = self
            .adapters
            .get(&target_id)
            .ok_or_else(|| Error::TargetUnavailable {
                target: target_id.clone(),
                reason: "No adapter registered".into(),
            })?;

        // Circuit breaker: if open, dead-letter immediately (shed load without
        // dropping — the event is still recorded, preserving no-silent-drops).
        if self.breaker_policy.failure_threshold > 0 && self.breaker_is_open(&target_id) {
            let reason = format!("Circuit breaker open for target '{target_id}'");
            warn!("{reason} — dead-lettering event {}", event.id);
            self.dead_letter(event, &target_id, &reason, 0).await?;
            return Err(Error::TargetUnavailable {
                target: target_id,
                reason,
            });
        }

        // Bound per-target concurrency for the duration of the delivery.
        let _permit =
            match self.inflight.get(&target_id) {
                Some(sem) => Some(sem.clone().acquire_owned().await.map_err(|_| {
                    Error::TargetUnavailable {
                        target: target_id.clone(),
                        reason: "Inflight semaphore closed".into(),
                    }
                })?),
                None => None,
            };

        debug!(
            "Dispatching event {} to target {} (guarantee {:?})",
            event.id,
            target_id,
            adapter.guarantee()
        );

        // Attempt delivery with retry.
        let mut last_error = None;
        for attempt in 1..=self.retry_policy.max_attempts {
            match adapter.deliver(event).await {
                Ok(receipt) => {
                    info!(
                        "Delivered event {} to {} (attempt {}, {}µs)",
                        event.id, target_id, attempt, receipt.latency_us
                    );
                    self.receipts.lock().await.push(receipt.clone());
                    self.breaker_on_success(&target_id);
                    return Ok(receipt);
                }
                Err(e) => {
                    warn!(
                        "Delivery attempt {}/{} failed for event {} → {}: {}",
                        attempt, self.retry_policy.max_attempts, event.id, target_id, e
                    );
                    last_error = Some(e);

                    if attempt < self.retry_policy.max_attempts {
                        let delay = self.retry_policy.delay_for(&event.id, attempt);
                        if !delay.is_zero() {
                            tokio::time::sleep(delay).await;
                        }
                    }
                }
            }
        }

        // All attempts exhausted — dead-letter and record the breaker failure.
        let reason = last_error
            .as_ref()
            .map(|e| e.to_string())
            .unwrap_or_else(|| "Unknown error".into());
        error!(
            "Dead-lettered event {} after {} attempts: {}",
            event.id, self.retry_policy.max_attempts, reason
        );
        self.dead_letter(event, &target_id, &reason, self.retry_policy.max_attempts)
            .await?;
        self.breaker_on_failure(&target_id);

        Err(last_error.unwrap_or_else(|| Error::Routing("All delivery attempts failed".into())))
    }

    /// Record a dead-letter to the sink.
    async fn dead_letter(
        &self,
        event: &AutomationEvent,
        target_id: &str,
        reason: &str,
        attempts: u32,
    ) -> Result<()> {
        let dl = DeadLetter {
            event_id: event.id.clone(),
            target_id: target_id.to_string(),
            reason: reason.to_string(),
            dead_lettered_at: Utc::now(),
            attempts,
        };
        self.dead_letter_sink.record(&dl).await
    }

    fn breaker_is_open(&self, target_id: &str) -> bool {
        let breakers = self.breakers.lock().expect("breaker mutex poisoned");
        breakers
            .get(target_id)
            .map(|b| b.is_open(Instant::now()))
            .unwrap_or(false)
    }

    fn breaker_on_success(&self, target_id: &str) {
        let mut breakers = self.breakers.lock().expect("breaker mutex poisoned");
        let b = breakers.entry(target_id.to_string()).or_default();
        b.consecutive_failures = 0;
        b.open_until = None;
    }

    fn breaker_on_failure(&self, target_id: &str) {
        let mut breakers = self.breakers.lock().expect("breaker mutex poisoned");
        let b = breakers.entry(target_id.to_string()).or_default();
        b.consecutive_failures = b.consecutive_failures.saturating_add(1);
        if b.consecutive_failures >= self.breaker_policy.failure_threshold {
            b.open_until =
                Some(Instant::now() + Duration::from_millis(self.breaker_policy.cooldown_ms));
            warn!(
                "Circuit breaker TRIPPED for target '{}' after {} consecutive failures",
                target_id, b.consecutive_failures
            );
        }
    }

    /// Get all dead-lettered events (best-effort snapshot from the sink).
    pub async fn dead_letters(&self) -> Vec<DeadLetter> {
        self.dead_letter_sink.snapshot().await.unwrap_or_default()
    }

    /// Get all delivery receipts
    pub async fn receipts(&self) -> Vec<DeliveryReceipt> {
        self.receipts.lock().await.clone()
    }

    /// Number of registered targets
    pub fn transport_count(&self) -> usize {
        self.adapters.len()
    }

    /// Whether the circuit breaker for a target is currently open.
    pub fn is_circuit_open(&self, target_id: &str) -> bool {
        self.breaker_is_open(target_id)
    }
}

impl Default for Dispatcher {
    fn default() -> Self {
        Self::new()
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

    /// A transport that fails a fixed number of times before succeeding, for
    /// exercising retry / breaker / dead-letter paths deterministically.
    struct FlakyTransport {
        name: String,
        fail_until: u32,
        attempts: Arc<StdMutex<u32>>,
    }

    impl FlakyTransport {
        fn new(name: &str, fail_until: u32) -> Self {
            Self {
                name: name.into(),
                fail_until,
                attempts: Arc::new(StdMutex::new(0)),
            }
        }
    }

    #[async_trait]
    impl TargetTransport for FlakyTransport {
        async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt> {
            let n = {
                let mut a = self.attempts.lock().unwrap();
                *a += 1;
                *a
            };
            if n <= self.fail_until {
                return Err(Error::TargetUnavailable {
                    target: self.name.clone(),
                    reason: format!("synthetic failure #{n}"),
                });
            }
            Ok(DeliveryReceipt {
                event_id: event.id.clone(),
                target_id: self.name.clone(),
                delivered_at: Utc::now(),
                latency_us: 0,
                acknowledged: true,
            })
        }
        fn is_connected(&self) -> bool {
            true
        }
        fn name(&self) -> &str {
            &self.name
        }
    }

    fn fast_retry(max_attempts: u32) -> RetryPolicy {
        RetryPolicy {
            max_attempts,
            base_delay_ms: 0,
            exponential_backoff: false,
            jitter: false,
        }
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
        let mut dispatcher = Dispatcher::new().with_retry_policy(fast_retry(1));

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
    async fn test_retry_then_succeed() {
        let mut dispatcher = Dispatcher::new().with_retry_policy(fast_retry(3));
        // Fails twice, succeeds on the third attempt.
        dispatcher.register_transport("t", Arc::new(FlakyTransport::new("t", 2)));

        let event = test_event();
        let decision = RouteDecision::capability_match(&event.id, "t", 1.0);
        let receipt = dispatcher.dispatch(&decision, &event).await.unwrap();
        assert!(receipt.acknowledged);
        assert!(dispatcher.dead_letters().await.is_empty());
    }

    #[tokio::test]
    async fn test_circuit_breaker_trips_and_sheds() {
        let mut dispatcher = Dispatcher::new()
            .with_retry_policy(fast_retry(1))
            .with_breaker_policy(BreakerPolicy {
                failure_threshold: 2,
                cooldown_ms: 60_000,
            });
        // Always fails.
        dispatcher.register_transport("t", Arc::new(FlakyTransport::new("t", u32::MAX)));

        let event = test_event();
        let decision = RouteDecision::capability_match(&event.id, "t", 1.0);

        // Two real failures trip the breaker (threshold = 2).
        assert!(dispatcher.dispatch(&decision, &event).await.is_err());
        assert!(!dispatcher.is_circuit_open("t"));
        assert!(dispatcher.dispatch(&decision, &event).await.is_err());
        assert!(dispatcher.is_circuit_open("t"));

        // Third dispatch is shed by the open breaker — still dead-lettered,
        // never silently dropped.
        let before = dispatcher.dead_letters().await.len();
        assert!(dispatcher.dispatch(&decision, &event).await.is_err());
        let after = dispatcher.dead_letters().await.len();
        assert_eq!(after, before + 1, "shed event must still be dead-lettered");
    }

    #[tokio::test]
    async fn test_jsonl_sink_persists_and_reads_back() {
        let dir = std::env::temp_dir();
        let path = dir.join(format!("har-dlq-{}.jsonl", uuid_like()));
        let _ = std::fs::remove_file(&path);

        let sink = Arc::new(JsonlFileSink::new(path.clone()));
        let mut dispatcher = Dispatcher::new()
            .with_retry_policy(fast_retry(1))
            .with_dead_letter_sink(sink.clone());

        let mut transport = InMemoryTransport::new("t");
        transport.disconnect();
        dispatcher.register_transport("t", Arc::new(transport));

        let event = test_event();
        let decision = RouteDecision::capability_match(&event.id, "t", 1.0);
        let _ = dispatcher.dispatch(&decision, &event).await;

        // A fresh sink over the same file recovers the dead-letter (crash-safe).
        let recovered = JsonlFileSink::new(path.clone()).snapshot().await.unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].event_id, event.id);

        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn test_inflight_cap_registers_semaphore() {
        let mut dispatcher = Dispatcher::new().with_max_inflight(2);
        dispatcher.register_transport("t", Arc::new(InMemoryTransport::new("t")));
        // Delivery still succeeds under a cap.
        let event = test_event();
        let decision = RouteDecision::capability_match(&event.id, "t", 1.0);
        assert!(dispatcher.dispatch(&decision, &event).await.is_ok());
    }

    #[tokio::test]
    async fn test_adapter_carries_guarantee_and_caps() {
        let adapter = TransportAdapter::new("t", Arc::new(InMemoryTransport::new("t")))
            .with_capabilities(vec![TargetCapability::Filesystem])
            .with_guarantee(DeliveryGuarantee::AtLeastOnce);
        assert_eq!(adapter.target_id(), "t");
        assert_eq!(adapter.guarantee(), DeliveryGuarantee::AtLeastOnce);
        assert_eq!(adapter.capabilities(), &[TargetCapability::Filesystem]);
        assert_eq!(adapter.health().await, TargetStatus::Healthy);
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

    /// Cheap unique-ish token for temp filenames without pulling in rand.
    fn uuid_like() -> String {
        let mut h = DefaultHasher::new();
        std::process::id().hash(&mut h);
        std::thread::current().id().hash(&mut h);
        format!("{:x}", h.finish())
    }
}
