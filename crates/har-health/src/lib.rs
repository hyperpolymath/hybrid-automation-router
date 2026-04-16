// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! HAR Health — Health checking for automation targets

#![forbid(unsafe_code)]
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use har_core::Result;
use har_core::TargetStatus;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

/// Result of probing a target
#[derive(Debug, Clone)]
pub struct ProbeResult {
    pub healthy: bool,
    pub latency_ms: u64,
    pub message: Option<String>,
}

/// Trait for health probes
#[async_trait]
pub trait HealthProbe: Send + Sync {
    async fn probe(&self, target_id: &str, endpoint: &str) -> Result<ProbeResult>;
    fn name(&self) -> &str;
}

/// Default probe that always returns healthy
pub struct DefaultProbe;

#[async_trait]
impl HealthProbe for DefaultProbe {
    async fn probe(&self, _target_id: &str, _endpoint: &str) -> Result<ProbeResult> {
        Ok(ProbeResult {
            healthy: true,
            latency_ms: 0,
            message: None,
        })
    }
    fn name(&self) -> &str {
        "default"
    }
}

/// Health status of a single target
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthStatus {
    pub target_id: String,
    pub status: TargetStatus,
    pub last_check: Option<DateTime<Utc>>,
    pub latency_ms: Option<u64>,
    pub consecutive_failures: u32,
    pub message: Option<String>,
}

impl HealthStatus {
    fn new(target_id: &str) -> Self {
        Self {
            target_id: target_id.to_string(),
            status: TargetStatus::Unknown,
            last_check: None,
            latency_ms: None,
            consecutive_failures: 0,
            message: None,
        }
    }

    fn record_success(&mut self, latency_ms: u64) {
        self.status = TargetStatus::Healthy;
        self.last_check = Some(Utc::now());
        self.latency_ms = Some(latency_ms);
        self.consecutive_failures = 0;
        self.message = None;
    }

    fn record_failure(&mut self, message: &str) {
        self.consecutive_failures += 1;
        self.last_check = Some(Utc::now());
        self.message = Some(message.to_string());
        self.status = if self.consecutive_failures >= 3 {
            TargetStatus::Unhealthy
        } else {
            TargetStatus::Degraded
        };
    }
}

struct TargetEntry {
    endpoint: String,
    probe: Arc<dyn HealthProbe>,
    status: HealthStatus,
}

/// Health checker that monitors automation targets
///
/// Supports both on-demand checking and background periodic checks.
///
/// ## Degradation logic
///
/// - 0 consecutive failures: `Healthy`
/// - 1-2 consecutive failures: `Degraded`
/// - 3+ consecutive failures: `Unhealthy`
/// - A successful probe resets failures to 0
pub struct HealthChecker {
    targets: Arc<Mutex<HashMap<String, TargetEntry>>>,
    /// Flag to control the background check task.
    running: Arc<AtomicBool>,
}

impl HealthChecker {
    pub fn new() -> Self {
        Self {
            targets: Arc::new(Mutex::new(HashMap::new())),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    pub async fn register_target(
        &self,
        id: impl Into<String>,
        endpoint: impl Into<String>,
        probe: Arc<dyn HealthProbe>,
    ) {
        let id = id.into();
        info!("HealthChecker: registered target '{}'", id);
        let mut targets = self.targets.lock().await;
        targets.insert(
            id.clone(),
            TargetEntry {
                endpoint: endpoint.into(),
                probe,
                status: HealthStatus::new(&id),
            },
        );
    }

    pub async fn check_target(&self, id: &str) -> Result<HealthStatus> {
        let mut targets = self.targets.lock().await;
        let entry = targets
            .get_mut(id)
            .ok_or_else(|| har_core::Error::Config(format!("Target '{}' not registered", id)))?;

        match entry.probe.probe(id, &entry.endpoint).await {
            Ok(result) if result.healthy => {
                entry.status.record_success(result.latency_ms);
                debug!("HealthCheck '{}': healthy ({}ms)", id, result.latency_ms);
            }
            Ok(result) => {
                let msg = result.message.unwrap_or_else(|| "Unhealthy".into());
                entry.status.record_failure(&msg);
                warn!("HealthCheck '{}': unhealthy — {}", id, msg);
            }
            Err(e) => {
                entry.status.record_failure(&e.to_string());
                warn!("HealthCheck '{}': probe error — {}", id, e);
            }
        }

        Ok(entry.status.clone())
    }

    pub async fn check_all(&self) -> Vec<HealthStatus> {
        let ids: Vec<String> = {
            let targets = self.targets.lock().await;
            targets.keys().cloned().collect()
        };

        let mut results = Vec::new();
        for id in ids {
            if let Ok(status) = self.check_target(&id).await {
                results.push(status);
            }
        }
        results
    }

    pub async fn get_status(&self, id: &str) -> Option<HealthStatus> {
        let targets = self.targets.lock().await;
        targets.get(id).map(|e| e.status.clone())
    }

    /// Start background periodic health checking.
    ///
    /// Spawns a Tokio task that runs [`check_all`](Self::check_all) at
    /// the given interval. Call [`stop`](Self::stop) to terminate it.
    pub fn start_background(&self, interval: Duration) -> tokio::task::JoinHandle<()> {
        self.running.store(true, Ordering::SeqCst);
        let running = Arc::clone(&self.running);
        let targets = Arc::clone(&self.targets);

        info!(
            interval_secs = interval.as_secs(),
            "Starting background health checks"
        );

        tokio::spawn(async move {
            while running.load(Ordering::SeqCst) {
                let ids: Vec<String> = {
                    let map = targets.lock().await;
                    map.keys().cloned().collect()
                };

                for id in &ids {
                    if !running.load(Ordering::SeqCst) {
                        break;
                    }
                    let mut map = targets.lock().await;
                    if let Some(entry) = map.get_mut(id.as_str()) {
                        match entry.probe.probe(id, &entry.endpoint).await {
                            Ok(result) if result.healthy => {
                                entry.status.record_success(result.latency_ms);
                            }
                            Ok(result) => {
                                let msg = result.message.unwrap_or_else(|| "Unhealthy".into());
                                entry.status.record_failure(&msg);
                            }
                            Err(e) => {
                                entry.status.record_failure(&e.to_string());
                            }
                        }
                    }
                }

                tokio::time::sleep(interval).await;
            }
            info!("Background health checks stopped");
        })
    }

    /// Stop the background health check task.
    pub fn stop(&self) {
        info!("Stopping background health checks");
        self.running.store(false, Ordering::SeqCst);
    }
}

impl Default for HealthChecker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FailingProbe;

    #[async_trait]
    impl HealthProbe for FailingProbe {
        async fn probe(&self, _id: &str, _endpoint: &str) -> Result<ProbeResult> {
            Ok(ProbeResult {
                healthy: false,
                latency_ms: 0,
                message: Some("Connection refused".into()),
            })
        }
        fn name(&self) -> &str {
            "failing"
        }
    }

    #[tokio::test]
    async fn test_default_probe_healthy() {
        let checker = HealthChecker::new();
        checker
            .register_target("test", "localhost:8080", Arc::new(DefaultProbe))
            .await;

        let status = checker.check_target("test").await.expect("TODO: handle error");
        assert_eq!(status.status, TargetStatus::Healthy);
        assert_eq!(status.consecutive_failures, 0);
    }

    #[tokio::test]
    async fn test_health_status_tracking() {
        let checker = HealthChecker::new();
        checker
            .register_target("tracked", "localhost:9090", Arc::new(DefaultProbe))
            .await;

        // Before any check: Unknown, no timestamp.
        let initial = checker.get_status("tracked").await.expect("TODO: handle error");
        assert_eq!(initial.status, TargetStatus::Unknown);
        assert!(initial.last_check.is_none());

        // After a check: Healthy with a timestamp and latency.
        let after = checker.check_target("tracked").await.expect("TODO: handle error");
        assert_eq!(after.status, TargetStatus::Healthy);
        assert!(after.last_check.is_some());
        assert_eq!(after.latency_ms, Some(0));
    }

    #[tokio::test]
    async fn test_degradation_after_failures() {
        let checker = HealthChecker::new();
        checker
            .register_target("test", "localhost:8080", Arc::new(FailingProbe))
            .await;

        let s1 = checker.check_target("test").await.expect("TODO: handle error");
        assert_eq!(s1.status, TargetStatus::Degraded);
        assert_eq!(s1.consecutive_failures, 1);

        let s2 = checker.check_target("test").await.expect("TODO: handle error");
        assert_eq!(s2.status, TargetStatus::Degraded);

        let s3 = checker.check_target("test").await.expect("TODO: handle error");
        assert_eq!(s3.status, TargetStatus::Unhealthy);
        assert_eq!(s3.consecutive_failures, 3);
    }

    #[tokio::test]
    async fn test_check_all() {
        let checker = HealthChecker::new();
        checker
            .register_target("t1", "localhost:1", Arc::new(DefaultProbe))
            .await;
        checker
            .register_target("t2", "localhost:2", Arc::new(DefaultProbe))
            .await;

        let results = checker.check_all().await;
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|s| s.status == TargetStatus::Healthy));
    }

    #[tokio::test]
    async fn test_unknown_target() {
        let checker = HealthChecker::new();
        assert!(checker.check_target("nonexistent").await.is_err());
    }
}
