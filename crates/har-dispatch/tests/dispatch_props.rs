// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Property tests for the dispatcher (issue #49 W5, PROOF-NEEDS RR-2).
//!
//! RR-2 is the runtime echo of the `noEventLoss` + `noDuplicateDispatch`
//! invariants: under an *arbitrary failure schedule*, a dispatched event ends
//! in exactly one terminal state — delivered once, or dead-lettered with
//! `attempts == max_attempts` — and never both, and never neither.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use har_core::{AutomationEvent, Error, EventSource, Result, RouteDecision};
use har_dispatch::{BreakerPolicy, DeliveryReceipt, Dispatcher, RetryPolicy, TargetTransport};
use proptest::prelude::*;

/// A transport with a scripted failure schedule: it fails its first
/// `fail_until` delivery attempts, then succeeds on every attempt after.
struct ScriptedTransport {
    name: String,
    fail_until: u32,
    attempts: Arc<Mutex<u32>>,
}

impl ScriptedTransport {
    fn new(name: &str, fail_until: u32) -> Self {
        Self {
            name: name.into(),
            fail_until,
            attempts: Arc::new(Mutex::new(0)),
        }
    }
}

#[async_trait]
impl TargetTransport for ScriptedTransport {
    async fn deliver(&self, event: &AutomationEvent) -> Result<DeliveryReceipt> {
        let n = {
            let mut a = self.attempts.lock().unwrap();
            *a += 1;
            *a
        };
        if n <= self.fail_until {
            return Err(Error::TargetUnavailable {
                target: self.name.clone(),
                reason: format!("scheduled failure #{n}"),
            });
        }
        Ok(DeliveryReceipt {
            event_id: event.id.clone(),
            target_id: self.name.clone(),
            delivered_at: chrono::Utc::now(),
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

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
}

proptest! {
    /// RR-2: deliver-once-or-dead-letter. For any failure schedule and any
    /// retry budget, the event ends in exactly one terminal state.
    #[test]
    fn deliver_once_or_dead_letter(
        max_attempts in 1u32..6,
        fail_until in 0u32..8,
    ) {
        rt().block_on(async move {
            let mut dispatcher = Dispatcher::new()
                .with_retry_policy(RetryPolicy {
                    max_attempts,
                    base_delay_ms: 0,
                    exponential_backoff: false,
                    jitter: false,
                })
                // Disable the breaker so this property isolates retry/DLQ.
                .with_breaker_policy(BreakerPolicy { failure_threshold: 0, cooldown_ms: 0 });

            dispatcher.register_transport(
                "t",
                Arc::new(ScriptedTransport::new("t", fail_until)),
            );

            let event = AutomationEvent::new(
                EventSource::Filesystem { path: "/tmp/x".into() },
                "filesystem",
            );
            let decision = RouteDecision::capability_match(&event.id, "t", 1.0);

            let result = dispatcher.dispatch(&decision, &event).await;
            let dead = dispatcher.dead_letters().await;
            let receipts = dispatcher.receipts().await;

            if fail_until < max_attempts {
                // Enough of the retry budget survives to deliver.
                prop_assert!(result.is_ok(), "expected delivery when fail_until < max_attempts");
                prop_assert_eq!(receipts.len(), 1, "exactly one delivery receipt");
                prop_assert!(dead.is_empty(), "no dead-letter on success");
            } else {
                // Budget exhausted → dead-lettered exactly once, never delivered.
                prop_assert!(result.is_err(), "expected failure when budget exhausted");
                prop_assert!(receipts.is_empty(), "no receipt on exhaustion");
                prop_assert_eq!(dead.len(), 1, "exactly one dead-letter");
                prop_assert_eq!(dead[0].event_id.clone(), event.id.clone());
                prop_assert_eq!(dead[0].attempts, max_attempts, "attempts == max_attempts");
            }
            Ok(())
        })?;
    }
}
