// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Property tests: the A2ML dialect round-trips arbitrary graphs, and the
//! lifecycle/handoff invariants hold for arbitrary histories.

use chrono::{DateTime, Utc};
use har_meta::{
    a2ml, AttrValue, Dependency, DependencyKind, Owner, RealisationStatus, Resource, ResourceGraph,
    ResourceId, ResourceKind,
};
use proptest::prelude::*;
use std::collections::BTreeSet;

fn t0() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-07-07T00:00:00Z")
        .unwrap()
        .with_timezone(&Utc)
}

fn attr_value() -> impl Strategy<Value = AttrValue> {
    prop_oneof![
        any::<bool>().prop_map(AttrValue::Bool),
        any::<i64>().prop_map(AttrValue::Int),
        // Arbitrary strings, including escapes-in-waiting
        ".{0,20}".prop_map(AttrValue::Str),
        prop::collection::vec(".{0,10}", 0..3).prop_map(AttrValue::StrList),
    ]
}

fn status() -> impl Strategy<Value = RealisationStatus> {
    prop_oneof![
        Just(RealisationStatus::Declared),
        Just(RealisationStatus::Planned),
        Just(RealisationStatus::Realised),
        Just(RealisationStatus::HandedOff),
    ]
}

fn dep_kind() -> impl Strategy<Value = DependencyKind> {
    prop_oneof![
        Just(DependencyKind::Before),
        Just(DependencyKind::Require),
        Just(DependencyKind::Notify),
    ]
}

/// A graph with unique ids, arbitrary scalar attributes, arbitrary statuses
/// reached through the FSM's permitted path, and edges between existing
/// resources
fn graph() -> impl Strategy<Value = ResourceGraph> {
    let ids = prop::collection::btree_set("[a-z][a-z0-9-]{0,6}", 1..8);
    ids.prop_flat_map(|ids| {
        let ids: Vec<String> = ids.into_iter().collect();
        let n = ids.len();
        let resources = prop::collection::vec(
            (
                prop::collection::btree_map("[a-z][a-z0-9_]{0,6}", attr_value(), 0..4),
                status(),
            ),
            n..=n,
        );
        let deps = prop::collection::vec((0..n, 0..n, dep_kind()), 0..n.min(4));
        (Just(ids), resources, deps).prop_map(|(ids, resources, deps)| {
            let mut g = ResourceGraph::new();
            for (id, (attrs, target_status)) in ids.iter().zip(&resources) {
                let mut r = Resource::new(
                    ResourceId::new(id.clone()).unwrap(),
                    ResourceKind::new("pkg.install").unwrap(),
                );
                for (name, value) in attrs {
                    r = r.with_attr(name.clone(), value.clone()).unwrap();
                }
                g.add_resource(r, Owner::new("har").unwrap(), t0()).unwrap();
                // Walk the FSM's permitted path to the target status
                let rid = ResourceId::new(id.clone()).unwrap();
                use RealisationStatus::*;
                let path: &[RealisationStatus] = match target_status {
                    Declared => &[],
                    Planned => &[Planned],
                    Realised => &[Planned, Realised],
                    HandedOff => &[Planned, Realised, HandedOff],
                };
                for step in path {
                    g.advance(&rid, *step, t0()).unwrap();
                }
            }
            let mut seen = BTreeSet::new();
            for (from, to, kind) in deps {
                if seen.insert((from, to, kind.as_str())) {
                    g.add_dependency(Dependency::new(
                        ResourceId::new(ids[from].clone()).unwrap(),
                        ResourceId::new(ids[to].clone()).unwrap(),
                        kind,
                    ))
                    .unwrap();
                }
            }
            g
        })
    })
}

proptest! {
    /// parse(emit(g)) reproduces g's semantics (everything the dialect
    /// carries: resources, owner, status, provider, dependencies)
    #[test]
    fn prop_round_trip_semantics(g in graph()) {
        let text = a2ml::emit(&g).unwrap();
        let parsed = a2ml::parse(&text).unwrap();
        prop_assert_eq!(parsed.len(), g.len());
        for entry in g.entries() {
            let p = parsed.get(&entry.resource.id).unwrap();
            prop_assert_eq!(&p.resource, &entry.resource);
            prop_assert_eq!(&p.provenance.owner, &entry.provenance.owner);
            prop_assert_eq!(p.provenance.status, entry.provenance.status);
            prop_assert_eq!(&p.provider, &entry.provider);
        }
        prop_assert_eq!(parsed.dependencies(), g.dependencies());
    }

    /// emit is canonical: emitting a parsed document reproduces it exactly
    #[test]
    fn prop_emit_idempotent(g in graph()) {
        let text = a2ml::emit(&g).unwrap();
        let again = a2ml::emit(&a2ml::parse(&text).unwrap()).unwrap();
        prop_assert_eq!(again, text);
    }

    /// execution_order is a permutation of the graph's ids that respects
    /// every edge's ordering — whenever it exists (acyclic edges)
    #[test]
    fn prop_execution_order_respects_edges(g in graph()) {
        if let Ok(order) = g.execution_order() {
            prop_assert_eq!(order.len(), g.len());
            let pos = |id: &ResourceId| order.iter().position(|o| o == id).unwrap();
            for dep in g.dependencies() {
                let (earlier, later) = dep.ordering();
                if earlier != later {
                    prop_assert!(pos(earlier) < pos(later));
                }
            }
        }
    }
}
