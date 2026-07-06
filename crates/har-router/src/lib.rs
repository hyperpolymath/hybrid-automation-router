// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! HAR Router — The routing engine that matches events to automation targets
//!
//! Evaluates incoming [`AutomationEvent`]s against registered targets
//! and produces [`RouteDecision`]s using configurable strategies.

#![forbid(unsafe_code)]
use har_core::{
    AllowAll, AutomationEvent, AutomationTarget, CapabilityVerifier, Error, Result, RouteDecision,
    RoutingContext, RoutingStrategy, TargetStatus,
};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::atomic::{AtomicUsize, Ordering};
use tracing::{debug, info, warn};

/// The main routing engine
pub struct Router {
    context: RoutingContext,
    default_strategy: RoutingStrategy,
    /// Rotation counter for the round-robin strategy. Interior mutability lets
    /// `route(&self)` advance it without requiring a `&mut` receiver.
    rr_counter: AtomicUsize,
    /// Pluggable policy gate applied to capability-matched candidates. Defaults
    /// to [`AllowAll`] (veto nothing), so capability-aware routing reduces to
    /// the structural intersection unless a stricter policy is installed.
    verifier: Box<dyn CapabilityVerifier>,
}

impl Router {
    /// Create a new router with default capability-match strategy
    pub fn new() -> Self {
        Self {
            context: RoutingContext::new(),
            default_strategy: RoutingStrategy::CapabilityMatch,
            rr_counter: AtomicUsize::new(0),
            verifier: Box::new(AllowAll),
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

    /// Install a capability-verification policy. Applied to the capability-
    /// matched candidate set, after the structural intersection and before
    /// strategy selection. The default is [`AllowAll`].
    pub fn with_verifier(mut self, verifier: Box<dyn CapabilityVerifier>) -> Self {
        self.verifier = verifier;
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

        // 3. Capability-based matching. `find_matching_targets` already
        //    applies the structural capability intersection (a target must
        //    declare every `required_capabilities` entry); here we additionally
        //    apply the pluggable policy verifier, which may veto otherwise-
        //    eligible targets (e.g. an unauthorised caller for a privileged
        //    capability).
        let matches: Vec<&AutomationTarget> = self
            .context
            .find_matching_targets(event)
            .into_iter()
            .filter(|t| self.verifier.verify(event, t))
            .collect();
        if matches.is_empty() {
            return Err(Error::NoTarget(format!(
                "No target can handle category '{}' with required capabilities {:?} (policy: {})",
                event.category,
                event.required_capabilities,
                self.verifier.name()
            )));
        }

        // 4. Final selection among the matching targets, governed by the
        //    configured strategy. Deterministic for a given (event, candidate
        //    set, load) — never dependent on HashMap iteration order.
        Ok(self.select(event, &matches))
    }

    /// Record the current pending-task load for a target (feeds `LeastLoaded`).
    pub fn set_load(&mut self, target_id: impl Into<String>, load: usize) {
        self.context.load.insert(target_id.into(), load);
    }

    /// Select one target from the non-empty candidate set per `default_strategy`.
    fn select(&self, event: &AutomationEvent, candidates: &[&AutomationTarget]) -> RouteDecision {
        let multi = candidates.len() > 1;
        match self.default_strategy {
            RoutingStrategy::RoundRobin => {
                let n = candidates.len();
                let idx = self.rr_counter.fetch_add(1, Ordering::Relaxed) % n;
                let chosen = candidates[idx];
                Self::decision(
                    event,
                    chosen,
                    candidates,
                    RoutingStrategy::RoundRobin,
                    if multi { 0.7 } else { 1.0 },
                    format!("Round-robin selection ({}/{})", idx + 1, n),
                )
            }
            RoutingStrategy::LeastLoaded => {
                let chosen = candidates
                    .iter()
                    .copied()
                    .min_by(|a, b| {
                        let la = self.context.load.get(&a.id).copied().unwrap_or(0);
                        let lb = self.context.load.get(&b.id).copied().unwrap_or(0);
                        la.cmp(&lb)
                            .then(b.weight.cmp(&a.weight))
                            .then(a.id.cmp(&b.id))
                    })
                    .expect("candidates non-empty");
                let load = self.context.load.get(&chosen.id).copied().unwrap_or(0);
                Self::decision(
                    event,
                    chosen,
                    candidates,
                    RoutingStrategy::LeastLoaded,
                    if multi { 0.85 } else { 1.0 },
                    format!("Least-loaded target ({load} pending)"),
                )
            }
            RoutingStrategy::WeightedRandom => {
                let chosen = Self::weighted_pick(event, candidates);
                Self::decision(
                    event,
                    chosen,
                    candidates,
                    RoutingStrategy::WeightedRandom,
                    if multi { 0.75 } else { 1.0 },
                    "Weighted-random selection (deterministic by event id)".to_string(),
                )
            }
            RoutingStrategy::Failover => {
                let mut ordered = candidates.to_vec();
                ordered.sort_by(|a, b| b.weight.cmp(&a.weight).then(a.id.cmp(&b.id)));
                let primary = ordered[0];
                let alternatives = ordered[1..].iter().map(|t| t.id.clone()).collect();
                RouteDecision {
                    event_id: event.id.clone(),
                    target_id: primary.id.clone(),
                    strategy: RoutingStrategy::Failover,
                    confidence: if multi { 0.9 } else { 1.0 },
                    alternatives,
                    reason: "Failover: primary target with ordered fallback chain".to_string(),
                }
            }
            // Direct / TagMatch / CapabilityMatch: event-triggered forms are
            // handled earlier in `route`; as a final selector they resolve to
            // highest weight (ties broken by id for a deterministic result).
            _ => {
                let chosen = candidates
                    .iter()
                    .copied()
                    .min_by(|a, b| b.weight.cmp(&a.weight).then(a.id.cmp(&b.id)))
                    .expect("candidates non-empty");
                let confidence = if multi { 0.8 } else { 1.0 };
                Self::decision(
                    event,
                    chosen,
                    candidates,
                    RoutingStrategy::CapabilityMatch,
                    confidence,
                    format!(
                        "Matched by capability (confidence: {:.0}%)",
                        confidence * 100.0
                    ),
                )
            }
        }
    }

    /// Build a decision, listing the non-chosen candidates as alternatives.
    fn decision(
        event: &AutomationEvent,
        chosen: &AutomationTarget,
        candidates: &[&AutomationTarget],
        strategy: RoutingStrategy,
        confidence: f64,
        reason: String,
    ) -> RouteDecision {
        let alternatives = candidates
            .iter()
            .filter(|t| t.id != chosen.id)
            .map(|t| t.id.clone())
            .collect();
        RouteDecision {
            event_id: event.id.clone(),
            target_id: chosen.id.clone(),
            strategy,
            confidence,
            alternatives,
            reason,
        }
    }

    /// Weight-proportional pick, made deterministic per event by seeding from
    /// the event id: it distributes across events in proportion to weight
    /// without carrying RNG state, and is reproducible for tests/attestation.
    fn weighted_pick<'a>(
        event: &AutomationEvent,
        candidates: &[&'a AutomationTarget],
    ) -> &'a AutomationTarget {
        let total: u64 = candidates.iter().map(|t| u64::from(t.weight.max(1))).sum();
        let mut hasher = DefaultHasher::new();
        event.id.hash(&mut hasher);
        let mut pick = hasher.finish() % total.max(1);
        for t in candidates {
            let w = u64::from(t.weight.max(1));
            if pick < w {
                return t;
            }
            pick -= w;
        }
        candidates[candidates.len() - 1]
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

    /// Build a router of N web-capable targets with explicit weights so the
    /// selection strategy has a real multi-target candidate set to choose from.
    fn router_with(strategy: RoutingStrategy, specs: &[(&str, u32)]) -> Router {
        let mut router = Router::new().with_strategy(strategy);
        for &(id, w) in specs {
            let mut t = AutomationTarget::new(id, id, format!("{id}-q"));
            t.status = TargetStatus::Healthy;
            t.capabilities = vec![TargetCapability::WebBrowser];
            t.weight = w;
            router.register_target(t);
        }
        router
    }

    fn web_event() -> AutomationEvent {
        AutomationEvent::new(
            EventSource::Webhook {
                endpoint: "/h".into(),
            },
            "web",
        )
    }

    #[test]
    fn round_robin_rotates_and_wraps() {
        let router = router_with(
            RoutingStrategy::RoundRobin,
            &[("t-a", 100), ("t-b", 100), ("t-c", 100)],
        );
        let ev = web_event();
        let picks: Vec<String> = (0..4)
            .map(|_| router.route(&ev).unwrap().target_id)
            .collect();
        assert_eq!(picks, vec!["t-a", "t-b", "t-c", "t-a"]);
        assert_eq!(
            router.route(&ev).unwrap().strategy,
            RoutingStrategy::RoundRobin
        );
    }

    #[test]
    fn least_loaded_picks_lowest_load() {
        let mut router = router_with(
            RoutingStrategy::LeastLoaded,
            &[("t-a", 100), ("t-b", 100), ("t-c", 100)],
        );
        router.set_load("t-a", 5);
        router.set_load("t-b", 1);
        router.set_load("t-c", 3);
        let d = router.route(&web_event()).unwrap();
        assert_eq!(d.target_id, "t-b");
        assert_eq!(d.strategy, RoutingStrategy::LeastLoaded);
    }

    #[test]
    fn weighted_random_is_deterministic_and_valid() {
        let router = router_with(
            RoutingStrategy::WeightedRandom,
            &[("t-a", 100), ("t-b", 100), ("t-c", 100)],
        );
        let ev = web_event();
        let a = router.route(&ev).unwrap().target_id;
        let b = router.route(&ev).unwrap().target_id;
        assert_eq!(a, b, "the same event must route the same way");
        assert!(["t-a", "t-b", "t-c"].contains(&a.as_str()));
        assert_eq!(
            router.route(&ev).unwrap().strategy,
            RoutingStrategy::WeightedRandom
        );
    }

    #[test]
    fn failover_primary_and_ordered_fallback_chain() {
        let router = router_with(
            RoutingStrategy::Failover,
            &[("t-a", 100), ("t-b", 300), ("t-c", 200)],
        );
        let d = router.route(&web_event()).unwrap();
        assert_eq!(d.strategy, RoutingStrategy::Failover);
        assert_eq!(d.target_id, "t-b"); // highest weight = primary
        assert_eq!(d.alternatives, vec!["t-c", "t-a"]); // fallbacks by weight desc
    }
}
