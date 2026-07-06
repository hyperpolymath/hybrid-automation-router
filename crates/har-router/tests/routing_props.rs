// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Property tests for the routing engine (issue #49 W5, PROOF-NEEDS RR-1/RR-3).
//!
//! These are the runtime echoes of the Idris2 routing invariants: RR-1 mirrors
//! "`route` is total / never invents a target", RR-3 mirrors
//! `deterministicSelection` ("the decision cannot depend on registration /
//! HashMap iteration order").

use std::collections::HashSet;

use har_core::{
    AutomationEvent, AutomationTarget, EventSource, RoutingStrategy, TargetCapability, TargetStatus,
};
use har_router::Router;
use proptest::prelude::*;

/// The full set of capabilities, and the categories each one handles, so we
/// can generate events that at least *some* target could service.
fn all_capabilities() -> Vec<TargetCapability> {
    vec![
        TargetCapability::Filesystem,
        TargetCapability::WebBrowser,
        TargetCapability::ApiIntegration,
        TargetCapability::DocumentProcessing,
        TargetCapability::Email,
        TargetCapability::DesktopGui,
        TargetCapability::Scheduling,
        TargetCapability::Plugin,
        TargetCapability::Ocr,
        TargetCapability::Nlp,
    ]
}

fn all_categories() -> Vec<String> {
    [
        "filesystem",
        "web",
        "api",
        "document",
        "email",
        "desktop",
        "scheduled",
        "plugin",
        "ocr",
        "nlp",
        "unknown", // deliberately unroutable
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

fn capability_strategy() -> impl Strategy<Value = TargetCapability> {
    proptest::sample::select(all_capabilities())
}

/// A generated target spec: id, weight, declared capabilities, availability.
#[derive(Debug, Clone)]
struct TargetSpec {
    id: String,
    weight: u32,
    caps: Vec<TargetCapability>,
    healthy: bool,
}

fn target_spec_strategy() -> impl Strategy<Value = TargetSpec> {
    (
        "[a-z][a-z0-9]{0,5}",
        1u32..1000,
        prop::collection::vec(capability_strategy(), 0..4),
        any::<bool>(),
    )
        .prop_map(|(id, weight, caps, healthy)| TargetSpec {
            id,
            weight,
            caps,
            healthy,
        })
}

fn build_target(spec: &TargetSpec) -> AutomationTarget {
    let mut t = AutomationTarget::new(spec.id.clone(), spec.id.clone(), format!("{}-q", spec.id));
    t.capabilities = spec.caps.clone();
    t.status = if spec.healthy {
        TargetStatus::Healthy
    } else {
        TargetStatus::Unhealthy
    };
    t.weight = spec.weight;
    t
}

fn event(category: &str) -> AutomationEvent {
    AutomationEvent::new(EventSource::Manual { user: None }, category.to_string())
}

proptest! {
    /// RR-1: `route` is total. For any set of targets and any event, routing
    /// either returns a decision whose target is one of the *registered*
    /// targets, or an error — it never panics and never invents a target.
    #[test]
    fn route_is_total_and_never_invents_a_target(
        specs in prop::collection::vec(target_spec_strategy(), 0..8),
        category in proptest::sample::select(all_categories()),
        req in prop::collection::vec(capability_strategy(), 0..3),
    ) {
        let mut router = Router::new();
        let mut ids = HashSet::new();
        for s in &specs {
            router.register_target(build_target(s));
            ids.insert(s.id.clone());
        }

        let mut ev = event(&category);
        for c in req {
            ev = ev.requiring(c);
        }

        match router.route(&ev) {
            Ok(decision) => {
                prop_assert!(
                    ids.contains(&decision.target_id),
                    "route returned unregistered target {:?}, registered = {:?}",
                    decision.target_id, ids
                );
                // Alternatives, too, must all be real registered targets.
                for alt in &decision.alternatives {
                    prop_assert!(ids.contains(alt), "alternative {alt:?} is not registered");
                }
            }
            Err(_) => { /* a routing error is an acceptable total outcome */ }
        }
    }

    /// RR-3: the routing decision is independent of the order in which targets
    /// are registered (i.e. cannot depend on HashMap/Vec iteration order). We
    /// use a deterministic strategy and distinct ids, and check that reversing
    /// and rotating the registration order yields the same chosen target.
    #[test]
    fn selection_is_registration_order_independent(
        specs in prop::collection::vec(target_spec_strategy(), 1..8),
        category in proptest::sample::select(all_categories()),
        rotate in 0usize..8,
    ) {
        // De-duplicate by id so the (weight desc, id asc) tie-break has a
        // unique winner regardless of order.
        let mut seen = HashSet::new();
        let mut unique: Vec<TargetSpec> = Vec::new();
        for s in specs {
            if seen.insert(s.id.clone()) {
                unique.push(s);
            }
        }

        let route_in = |order: &[TargetSpec]| {
            let mut router = Router::new().with_strategy(RoutingStrategy::CapabilityMatch);
            for s in order {
                router.register_target(build_target(s));
            }
            router.route(&event(&category)).ok().map(|d| d.target_id)
        };

        let forward = route_in(&unique);

        let mut reversed = unique.clone();
        reversed.reverse();
        let backward = route_in(&reversed);

        let mut rotated = unique.clone();
        let len = rotated.len();
        if len > 0 {
            rotated.rotate_left(rotate % len);
        }
        let rotated_pick = route_in(&rotated);

        prop_assert_eq!(&forward, &backward, "reversing registration changed the decision");
        prop_assert_eq!(&forward, &rotated_pick, "rotating registration changed the decision");
    }
}
