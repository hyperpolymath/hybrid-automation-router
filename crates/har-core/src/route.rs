// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Routing decisions and strategies
//!
//! The router evaluates events against registered targets and produces
//! routing decisions. Multiple strategies are supported for different
//! use cases.

use crate::event::AutomationEvent;
use crate::target::AutomationTarget;
use serde::{Deserialize, Serialize};

/// The router's decision about where to send an event
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteDecision {
    /// Event being routed
    pub event_id: String,
    /// Selected target ID
    pub target_id: String,
    /// Strategy used to make the decision
    pub strategy: RoutingStrategy,
    /// Confidence score (0.0 = no confidence, 1.0 = certain)
    pub confidence: f64,
    /// Alternative targets considered (ordered by preference)
    pub alternatives: Vec<String>,
    /// Reason for the decision (human-readable)
    pub reason: String,
}

impl RouteDecision {
    /// Create a direct route (target hint or exact match)
    pub fn direct(event_id: &str, target_id: &str) -> Self {
        Self {
            event_id: event_id.to_string(),
            target_id: target_id.to_string(),
            strategy: RoutingStrategy::Direct,
            confidence: 1.0,
            alternatives: Vec::new(),
            reason: "Direct target hint".to_string(),
        }
    }

    /// Create a capability-matched route
    pub fn capability_match(event_id: &str, target_id: &str, confidence: f64) -> Self {
        Self {
            event_id: event_id.to_string(),
            target_id: target_id.to_string(),
            strategy: RoutingStrategy::CapabilityMatch,
            confidence,
            alternatives: Vec::new(),
            reason: format!(
                "Matched by capability (confidence: {:.0}%)",
                confidence * 100.0
            ),
        }
    }

    /// Add alternative targets
    pub fn with_alternatives(mut self, alts: Vec<String>) -> Self {
        self.alternatives = alts;
        self
    }
}

/// Strategy used for routing decisions
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RoutingStrategy {
    /// Direct routing via target hint (bypass all rules)
    Direct,
    /// Match event category to target capabilities
    CapabilityMatch,
    /// Tag-based routing rules
    TagMatch,
    /// Round-robin across matching targets
    RoundRobin,
    /// Weighted random selection
    WeightedRandom,
    /// Route to target with lowest load
    LeastLoaded,
    /// Failover: try primary, fall back to alternatives
    Failover,
}

/// Context provided to the routing engine for making decisions
#[derive(Debug, Clone)]
pub struct RoutingContext {
    /// All registered targets
    pub targets: Vec<AutomationTarget>,
    /// Current load per target (target_id → pending task count)
    pub load: std::collections::HashMap<String, usize>,
    /// Routing rules (tag → target_id mappings)
    pub tag_rules: std::collections::HashMap<String, Vec<String>>,
}

impl RoutingContext {
    /// Create a new empty routing context
    pub fn new() -> Self {
        Self {
            targets: Vec::new(),
            load: std::collections::HashMap::new(),
            tag_rules: std::collections::HashMap::new(),
        }
    }

    /// Register an automation target
    pub fn register_target(&mut self, target: AutomationTarget) {
        self.targets.push(target);
    }

    /// Add a tag-based routing rule
    pub fn add_tag_rule(&mut self, tag: impl Into<String>, target_id: impl Into<String>) {
        self.tag_rules
            .entry(tag.into())
            .or_default()
            .push(target_id.into());
    }

    /// Find targets that can handle an event
    pub fn find_matching_targets(&self, event: &AutomationEvent) -> Vec<&AutomationTarget> {
        self.targets
            .iter()
            .filter(|t| t.is_available() && t.can_handle(&event.category))
            .collect()
    }
}

impl Default for RoutingContext {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{AutomationEvent, EventSource};
    use crate::target::{AutomationTarget, TargetStatus};

    #[test]
    fn test_find_matching_targets() {
        let mut ctx = RoutingContext::new();

        let mut rpa = AutomationTarget::rpa_elysium("rpa-queue");
        rpa.status = TargetStatus::Healthy;
        ctx.register_target(rpa);

        let mut web = AutomationTarget::new("web-auto", "Web Automation", "web-queue");
        web.status = TargetStatus::Healthy;
        web.capabilities = vec![crate::target::TargetCapability::WebBrowser];
        ctx.register_target(web);

        let fs_event = AutomationEvent::new(
            EventSource::Filesystem {
                path: "/tmp/test".into(),
            },
            "filesystem",
        );

        let matches = ctx.find_matching_targets(&fs_event);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].id, "rpa-elysium");
    }
}
