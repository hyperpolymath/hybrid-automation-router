// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! HAR Metrics — Metrics collection for routing decisions

#![forbid(unsafe_code)]
use chrono::{DateTime, Utc};
use har_core::RouteDecision;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// Collects metrics about routing decisions and dispatch outcomes
pub struct MetricsCollector {
    events_routed: AtomicU64,
    events_dropped: AtomicU64,
    events_dead_lettered: AtomicU64,
    strategy_counts: Mutex<HashMap<String, u64>>,
    category_counts: Mutex<HashMap<String, u64>>,
    target_counts: Mutex<HashMap<String, u64>>,
    latencies: Mutex<Vec<u64>>,
}

impl MetricsCollector {
    pub fn new() -> Self {
        Self {
            events_routed: AtomicU64::new(0),
            events_dropped: AtomicU64::new(0),
            events_dead_lettered: AtomicU64::new(0),
            strategy_counts: Mutex::new(HashMap::new()),
            category_counts: Mutex::new(HashMap::new()),
            target_counts: Mutex::new(HashMap::new()),
            latencies: Mutex::new(Vec::new()),
        }
    }

    /// Record a successful route decision
    pub fn record_route(&self, decision: &RouteDecision, latency_us: u64) {
        self.events_routed.fetch_add(1, Ordering::Relaxed);

        let strategy = format!("{:?}", decision.strategy);
        *self
            .strategy_counts
            .lock()
            .expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations")
            .entry(strategy)
            .or_insert(0) += 1;
        *self
            .target_counts
            .lock()
            .expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations")
            .entry(decision.target_id.clone())
            .or_insert(0) += 1;

        let mut lat = self.latencies.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations");
        lat.push(latency_us);
        // Keep only last 10000 entries
        if lat.len() > 10000 {
            let excess = lat.len() - 10000;
            lat.drain(0..excess);
        }
    }

    /// Record an event category
    pub fn record_category(&self, category: &str) {
        *self
            .category_counts
            .lock()
            .expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations")
            .entry(category.to_string())
            .or_insert(0) += 1;
    }

    /// Record a dropped event
    pub fn record_drop(&self) {
        self.events_dropped.fetch_add(1, Ordering::Relaxed);
    }

    /// Record a dead-lettered event
    pub fn record_dead_letter(&self) {
        self.events_dead_lettered.fetch_add(1, Ordering::Relaxed);
    }

    pub fn total_routed(&self) -> u64 {
        self.events_routed.load(Ordering::Relaxed)
    }

    pub fn total_dropped(&self) -> u64 {
        self.events_dropped.load(Ordering::Relaxed)
    }

    /// Success rate = routed / (routed + dropped + dead_lettered)
    pub fn success_rate(&self) -> f64 {
        let routed = self.events_routed.load(Ordering::Relaxed) as f64;
        let dropped = self.events_dropped.load(Ordering::Relaxed) as f64;
        let dead = self.events_dead_lettered.load(Ordering::Relaxed) as f64;
        let total = routed + dropped + dead;
        if total == 0.0 {
            1.0
        } else {
            routed / total
        }
    }

    pub fn avg_latency_us(&self) -> f64 {
        let lat = self.latencies.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations");
        if lat.is_empty() {
            0.0
        } else {
            lat.iter().sum::<u64>() as f64 / lat.len() as f64
        }
    }

    pub fn strategy_breakdown(&self) -> HashMap<String, u64> {
        self.strategy_counts.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations").clone()
    }

    pub fn category_breakdown(&self) -> HashMap<String, u64> {
        self.category_counts.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations").clone()
    }

    pub fn target_breakdown(&self) -> HashMap<String, u64> {
        self.target_counts.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations").clone()
    }

    /// Take a point-in-time snapshot
    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            timestamp: Utc::now(),
            total_routed: self.events_routed.load(Ordering::Relaxed),
            total_dropped: self.events_dropped.load(Ordering::Relaxed),
            total_dead_lettered: self.events_dead_lettered.load(Ordering::Relaxed),
            success_rate: self.success_rate(),
            avg_latency_us: self.avg_latency_us(),
            strategy_breakdown: self.strategy_breakdown(),
            category_breakdown: self.category_breakdown(),
            target_breakdown: self.target_breakdown(),
        }
    }

    /// Reset all metrics
    pub fn reset(&self) {
        self.events_routed.store(0, Ordering::Relaxed);
        self.events_dropped.store(0, Ordering::Relaxed);
        self.events_dead_lettered.store(0, Ordering::Relaxed);
        self.strategy_counts.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations").clear();
        self.category_counts.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations").clear();
        self.target_counts.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations").clear();
        self.latencies.lock().expect("metrics mutex never poisons — critical sections are simple HashMap insert/clear with no panic-able operations").clear();
    }
}

impl Default for MetricsCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Point-in-time metrics snapshot
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetricsSnapshot {
    pub timestamp: DateTime<Utc>,
    pub total_routed: u64,
    pub total_dropped: u64,
    pub total_dead_lettered: u64,
    pub success_rate: f64,
    pub avg_latency_us: f64,
    pub strategy_breakdown: HashMap<String, u64>,
    pub category_breakdown: HashMap<String, u64>,
    pub target_breakdown: HashMap<String, u64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_decision() -> RouteDecision {
        RouteDecision::capability_match("evt-1", "rpa-elysium", 0.95)
    }

    #[test]
    fn test_record_route() {
        let m = MetricsCollector::new();
        m.record_route(&test_decision(), 500);
        assert_eq!(m.total_routed(), 1);
        assert_eq!(m.avg_latency_us(), 500.0);
    }

    #[test]
    fn test_record_drop() {
        let m = MetricsCollector::new();
        m.record_drop();
        m.record_drop();
        assert_eq!(m.total_dropped(), 2);
    }

    #[test]
    fn test_success_rate() {
        let m = MetricsCollector::new();
        m.record_route(&test_decision(), 100);
        m.record_route(&test_decision(), 200);
        m.record_drop();
        // 2 routed / (2 routed + 1 dropped) = 0.666...
        assert!((m.success_rate() - 0.6666).abs() < 0.01);
    }

    #[test]
    fn test_strategy_breakdown() {
        let m = MetricsCollector::new();
        m.record_route(&test_decision(), 100);
        m.record_route(&test_decision(), 200);
        let breakdown = m.strategy_breakdown();
        assert_eq!(*breakdown.get("CapabilityMatch").unwrap(), 2);
    }

    #[test]
    fn test_snapshot() {
        let m = MetricsCollector::new();
        m.record_route(&test_decision(), 100);
        m.record_category("filesystem");
        let snap = m.snapshot();
        assert_eq!(snap.total_routed, 1);
        assert_eq!(*snap.category_breakdown.get("filesystem").unwrap(), 1);
    }

    #[test]
    fn test_reset() {
        let m = MetricsCollector::new();
        m.record_route(&test_decision(), 100);
        m.record_drop();
        m.reset();
        assert_eq!(m.total_routed(), 0);
        assert_eq!(m.total_dropped(), 0);
        assert_eq!(m.success_rate(), 1.0);
    }
}
