// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! HAR Router — The routing engine that matches events to automation targets
//!
//! Evaluates incoming [`AutomationEvent`]s against registered targets
//! and produces [`RouteDecision`]s using configurable strategies.

#![forbid(unsafe_code)]
use har_core::{
    AutomationEvent, AutomationTarget, Error, Result, RouteDecision, RoutingContext,
    RoutingStrategy, TargetStatus,
};
use tracing::{debug, info, warn};

/// The main routing engine
pub struct Router {
    context: RoutingContext,
    default_strategy: RoutingStrategy,
}

impl Router {
    /// Create a new router with default capability-match strategy
    pub fn new() -> Self {
        Self {
            context: RoutingContext::new(),
            default_strategy: RoutingStrategy::CapabilityMatch,
        }
    }

    /// Register an automation target
    pub fn register_target(&mut self, target: AutomationTarget) {
        info!("Registered target: {} ({})", target.name, target.id);
        self.context.register_target(target);
    }

    /// Add a tag-based routing rule
    pub fn add_tag_rule(&mut self, tag: impl Into<String>, target_id: impl Into<String>) {
        self.context.add_tag_rule(tag, target_id);
    }

    /// Set the default routing strategy
    pub fn with_strategy(mut self, strategy: RoutingStrategy) -> Self {
        self.default_strategy = strategy;
        self
    }

    /// Update a target's status (e.g., from health check)
    pub fn update_target_status(&mut self, target_id: &str, status: TargetStatus) {
        if let Some(target) = self.context.targets.iter_mut().find(|t| t.id == target_id) {
            target.status = status;
            debug!("Updated target '{}' status to {:?}", target_id, status);
        }
    }

    /// Route an event to the best matching target
    pub fn route(&self, event: &AutomationEvent) -> Result<RouteDecision> {
        debug!("Routing event {} (category: {})", event.id, event.category);

        // 1. Check for direct target hint
        if let Some(ref hint) = event.target_hint {
            if self
                .context
                .targets
                .iter()
                .any(|t| t.id == *hint && t.is_available())
            {
                return Ok(RouteDecision::direct(&event.id, hint));
            }
            warn!(
                "Target hint '{}' not available, falling back to routing",
                hint
            );
        }

        // 2. Check tag-based rules
        for tag in &event.tags {
            if let Some(target_ids) = self.context.tag_rules.get(tag) {
                for target_id in target_ids {
                    if self
                        .context
                        .targets
                        .iter()
                        .any(|t| t.id == *target_id && t.is_available())
                    {
                        return Ok(RouteDecision {
                            event_id: event.id.clone(),
                            target_id: target_id.clone(),
                            strategy: RoutingStrategy::TagMatch,
                            confidence: 0.9,
                            alternatives: Vec::new(),
                            reason: format!("Matched tag '{}'", tag),
                        });
                    }
                }
            }
        }

        // 3. Capability-based matching
        let matches = self.context.find_matching_targets(event);
        if matches.is_empty() {
            return Err(Error::NoTarget(format!(
                "No target can handle category '{}'",
                event.category
            )));
        }

        // Select best match by weight
        let best = matches
            .iter()
            .max_by_key(|t| t.weight)
            .expect("matches is non-empty");

        let alternatives: Vec<String> = matches
            .iter()
            .filter(|t| t.id != best.id)
            .map(|t| t.id.clone())
            .collect();

        let confidence = if matches.len() == 1 { 1.0 } else { 0.8 };

        Ok(
            RouteDecision::capability_match(&event.id, &best.id, confidence)
                .with_alternatives(alternatives),
        )
    }

    /// Get all registered targets
    pub fn targets(&self) -> &[AutomationTarget] {
        &self.context.targets
    }
}

impl Default for Router {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use har_core::{EventSource, TargetCapability};

    fn setup_router() -> Router {
        let mut router = Router::new();

        let mut rpa = AutomationTarget::rpa_elysium("rpa-queue");
        rpa.status = TargetStatus::Healthy;
        router.register_target(rpa);

        let mut web = AutomationTarget::new("web-auto", "Web Automation", "web-queue");
        web.status = TargetStatus::Healthy;
        web.capabilities = vec![
            TargetCapability::WebBrowser,
            TargetCapability::ApiIntegration,
        ];
        router.register_target(web);

        router
    }

    #[test]
    fn test_route_filesystem_to_rpa() {
        let router = setup_router();
        let event = AutomationEvent::new(
            EventSource::Filesystem {
                path: "/tmp/test".into(),
            },
            "filesystem",
        );

        let decision = router.route(&event).unwrap();
        assert_eq!(decision.target_id, "rpa-elysium");
        assert_eq!(decision.strategy, RoutingStrategy::CapabilityMatch);
    }

    #[test]
    fn test_route_web_to_web_auto() {
        let router = setup_router();
        let event = AutomationEvent::new(
            EventSource::Webhook {
                endpoint: "/hook".into(),
            },
            "web",
        );

        let decision = router.route(&event).unwrap();
        assert_eq!(decision.target_id, "web-auto");
    }

    #[test]
    fn test_direct_target_hint() {
        let router = setup_router();
        let event = AutomationEvent::new(EventSource::Manual { user: None }, "filesystem")
            .with_target_hint("web-auto");

        let decision = router.route(&event).unwrap();
        assert_eq!(decision.target_id, "web-auto");
        assert_eq!(decision.strategy, RoutingStrategy::Direct);
    }

    #[test]
    fn test_no_matching_target() {
        let router = setup_router();
        let event = AutomationEvent::new(EventSource::Manual { user: None }, "desktop");

        assert!(router.route(&event).is_err());
    }

    #[test]
    fn test_tag_based_routing() {
        let mut router = setup_router();
        router.add_tag_rule("urgent-fs", "rpa-elysium");

        let event = AutomationEvent::new(EventSource::Manual { user: None }, "unknown")
            .with_tag("urgent-fs");

        let decision = router.route(&event).unwrap();
        assert_eq!(decision.target_id, "rpa-elysium");
        assert_eq!(decision.strategy, RoutingStrategy::TagMatch);
    }
}
