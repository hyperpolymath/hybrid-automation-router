// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! The resource graph — the declarative level of the two-level IR
//!
//! Nodes are resources (with provenance and an optional provider); edges
//! are dependencies. [`ResourceGraph::execution_order`] is the seed of
//! *lowering* (graph -> plan): a deterministic topological order over the
//! ordering each edge imposes, rejecting cycles. The full plan
//! representation (idempotent primitive ops with pre/post conditions)
//! arrives with `har-il`.

use crate::dependency::Dependency;
use crate::error::{Error, Result};
use crate::handoff::HandoffCheckpoint;
use crate::provenance::{Owner, Provenance, Provider};
use crate::resource::{Resource, ResourceId};
use crate::state::RealisationStatus;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// A resource together with its provenance and (optional) provider
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceEntry {
    /// The desired resource
    pub resource: Resource,
    /// Who owns it and how it got here
    pub provenance: Provenance,
    /// The provider selected to realise it, once known
    pub provider: Option<Provider>,
}

/// Resources plus dependency edges: the declarative level
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceGraph {
    entries: BTreeMap<ResourceId, ResourceEntry>,
    dependencies: Vec<Dependency>,
}

impl ResourceGraph {
    /// Create an empty graph
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a resource under an owner (initial status: declared)
    pub fn add_resource(
        &mut self,
        resource: Resource,
        owner: Owner,
        at: DateTime<Utc>,
    ) -> Result<()> {
        if self.entries.contains_key(&resource.id) {
            return Err(Error::DuplicateResource(resource.id.to_string()));
        }
        let provenance = Provenance::declared(owner, at);
        self.entries.insert(
            resource.id.clone(),
            ResourceEntry {
                resource,
                provenance,
                provider: None,
            },
        );
        Ok(())
    }

    /// Insert a fully-formed entry (used by importers such as the A2ML
    /// parser, where provenance arrives from the wire rather than starting
    /// at declared)
    pub fn insert_entry(&mut self, entry: ResourceEntry) -> Result<()> {
        if self.entries.contains_key(&entry.resource.id) {
            return Err(Error::DuplicateResource(entry.resource.id.to_string()));
        }
        self.entries.insert(entry.resource.id.clone(), entry);
        Ok(())
    }

    /// Add a dependency edge; both endpoints must already be in the graph
    pub fn add_dependency(&mut self, dep: Dependency) -> Result<()> {
        for end in [&dep.from, &dep.to] {
            if !self.entries.contains_key(end) {
                return Err(Error::UnknownResource(end.to_string()));
            }
        }
        self.dependencies.push(dep);
        Ok(())
    }

    /// Look up a resource entry
    pub fn get(&self, id: &ResourceId) -> Option<&ResourceEntry> {
        self.entries.get(id)
    }

    /// Iterate entries in id order
    pub fn entries(&self) -> impl Iterator<Item = &ResourceEntry> {
        self.entries.values()
    }

    /// The dependency edges, in insertion order
    pub fn dependencies(&self) -> &[Dependency] {
        &self.dependencies
    }

    /// Number of resources
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the graph has no resources
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Advance a resource's lifecycle, enforcing the realisation FSM
    pub fn advance(
        &mut self,
        id: &ResourceId,
        to: RealisationStatus,
        at: DateTime<Utc>,
    ) -> Result<()> {
        let entry = self
            .entries
            .get_mut(id)
            .ok_or_else(|| Error::UnknownResource(id.to_string()))?;
        entry.provenance.advance(to, at)
    }

    /// Record the provider selected to realise a resource
    pub fn set_provider(&mut self, id: &ResourceId, provider: Provider) -> Result<()> {
        let entry = self
            .entries
            .get_mut(id)
            .ok_or_else(|| Error::UnknownResource(id.to_string()))?;
        entry.provider = Some(provider);
        Ok(())
    }

    /// Transfer ownership of a set of resources: the handoff move
    ///
    /// Linear: every resource must currently belong to `from` and not be
    /// terminal, and the set must not contain duplicates. Validation runs
    /// before any mutation, so a failed handoff transfers nothing.
    pub fn hand_off(
        &mut self,
        ids: &[ResourceId],
        from: &Owner,
        to: Owner,
        at: DateTime<Utc>,
    ) -> Result<HandoffCheckpoint> {
        let mut seen = BTreeSet::new();
        for id in ids {
            if !seen.insert(id) {
                return Err(Error::HandoffViolation(format!("duplicate resource {id}")));
            }
            let entry = self
                .entries
                .get(id)
                .ok_or_else(|| Error::UnknownResource(id.to_string()))?;
            if &entry.provenance.owner != from {
                return Err(Error::HandoffViolation(format!(
                    "resource {id} is owned by {}, not {from}",
                    entry.provenance.owner
                )));
            }
            if entry.provenance.status.is_terminal() {
                return Err(Error::HandoffViolation(format!(
                    "resource {id} already handed off"
                )));
            }
        }
        if from == &to {
            return Err(Error::HandoffViolation(format!(
                "transfer to current owner {to}"
            )));
        }
        for id in ids {
            // Validated above; transfer cannot fail now.
            self.entries
                .get_mut(id)
                .expect("validated")
                .provenance
                .transfer(to.clone(), at)?;
        }
        let mut resources: Vec<ResourceId> = ids.to_vec();
        resources.sort();
        Ok(HandoffCheckpoint {
            from: from.clone(),
            to,
            resources,
            at,
        })
    }

    /// A deterministic topological order over the edge orderings
    ///
    /// The seed of lowering: Kahn's algorithm with ready nodes taken in id
    /// order, so equal graphs always produce the same plan order. Returns
    /// [`Error::DependencyCycle`] (with the ids on one cycle) if the edges
    /// are cyclic.
    pub fn execution_order(&self) -> Result<Vec<ResourceId>> {
        let mut successors: BTreeMap<&ResourceId, Vec<&ResourceId>> = BTreeMap::new();
        let mut in_degree: BTreeMap<&ResourceId, usize> =
            self.entries.keys().map(|id| (id, 0)).collect();
        for dep in &self.dependencies {
            let (earlier, later) = dep.ordering();
            successors.entry(earlier).or_default().push(later);
            *in_degree.get_mut(later).expect("endpoints validated") += 1;
        }

        let mut ready: BTreeSet<&ResourceId> = in_degree
            .iter()
            .filter(|(_, d)| **d == 0)
            .map(|(id, _)| *id)
            .collect();
        let mut order = Vec::with_capacity(self.entries.len());
        while let Some(id) = ready.pop_first() {
            order.push(id.clone());
            for next in successors.get(id).into_iter().flatten() {
                let d = in_degree.get_mut(next).expect("endpoints validated");
                *d -= 1;
                if *d == 0 {
                    ready.insert(next);
                }
            }
        }

        if order.len() == self.entries.len() {
            Ok(order)
        } else {
            Err(Error::DependencyCycle(self.find_cycle()))
        }
    }

    /// Walk successor edges from an unresolved node until one repeats,
    /// returning the ids on the cycle (for the error message)
    fn find_cycle(&self) -> Vec<String> {
        let mut successors: BTreeMap<&ResourceId, Vec<&ResourceId>> = BTreeMap::new();
        for dep in &self.dependencies {
            let (earlier, later) = dep.ordering();
            successors.entry(earlier).or_default().push(later);
        }
        // Depth-first from each node until a node repeats on the stack.
        fn dfs<'a>(
            node: &'a ResourceId,
            successors: &BTreeMap<&'a ResourceId, Vec<&'a ResourceId>>,
            stack: &mut Vec<&'a ResourceId>,
            visited: &mut BTreeSet<&'a ResourceId>,
        ) -> Option<Vec<String>> {
            if let Some(pos) = stack.iter().position(|n| *n == node) {
                let mut cycle: Vec<String> = stack[pos..].iter().map(|n| n.to_string()).collect();
                cycle.push(node.to_string());
                return Some(cycle);
            }
            if !visited.insert(node) {
                return None;
            }
            stack.push(node);
            for next in successors.get(node).into_iter().flatten() {
                if let Some(cycle) = dfs(next, successors, stack, visited) {
                    return Some(cycle);
                }
            }
            stack.pop();
            None
        }
        let mut visited = BTreeSet::new();
        for node in self.entries.keys() {
            if let Some(cycle) = dfs(node, &successors, &mut Vec::new(), &mut visited) {
                return cycle;
            }
        }
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dependency::DependencyKind;
    use crate::resource::ResourceKind;

    fn t0() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-07-07T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    fn id(s: &str) -> ResourceId {
        ResourceId::new(s).unwrap()
    }

    fn graph(ids: &[&str]) -> ResourceGraph {
        let mut g = ResourceGraph::new();
        for s in ids {
            g.add_resource(
                Resource::new(id(s), ResourceKind::new("har.route").unwrap()),
                Owner::new("har").unwrap(),
                t0(),
            )
            .unwrap();
        }
        g
    }

    #[test]
    fn test_duplicate_and_unknown_rejected() {
        let mut g = graph(&["a"]);
        let dup = Resource::new(id("a"), ResourceKind::new("har.route").unwrap());
        assert!(matches!(
            g.add_resource(dup, Owner::new("har").unwrap(), t0()),
            Err(Error::DuplicateResource(_))
        ));
        assert!(matches!(
            g.add_dependency(Dependency::new(
                id("a"),
                id("ghost"),
                DependencyKind::Before
            )),
            Err(Error::UnknownResource(_))
        ));
    }

    #[test]
    fn test_execution_order_respects_edges() {
        let mut g = graph(&["c", "a", "b"]);
        // a before b; c requires b (so b earlier than c)
        g.add_dependency(Dependency::new(id("a"), id("b"), DependencyKind::Before))
            .unwrap();
        g.add_dependency(Dependency::new(id("c"), id("b"), DependencyKind::Require))
            .unwrap();
        let order = g.execution_order().unwrap();
        let pos = |s: &str| order.iter().position(|i| i.as_str() == s).unwrap();
        assert!(pos("a") < pos("b"));
        assert!(pos("b") < pos("c"));
    }

    #[test]
    fn test_execution_order_deterministic_without_edges() {
        let g = graph(&["z", "m", "a"]);
        let order = g.execution_order().unwrap();
        let names: Vec<&str> = order.iter().map(|i| i.as_str()).collect();
        assert_eq!(names, vec!["a", "m", "z"]);
    }

    #[test]
    fn test_cycle_detected() {
        let mut g = graph(&["a", "b"]);
        g.add_dependency(Dependency::new(id("a"), id("b"), DependencyKind::Before))
            .unwrap();
        g.add_dependency(Dependency::new(id("b"), id("a"), DependencyKind::Notify))
            .unwrap();
        match g.execution_order() {
            Err(Error::DependencyCycle(cycle)) => {
                assert!(cycle.len() >= 3); // a -> b -> a
            }
            other => panic!("expected cycle, got {other:?}"),
        }
    }

    #[test]
    fn test_hand_off_all_or_nothing() {
        let mut g = graph(&["a", "b"]);
        let har = Owner::new("har").unwrap();
        let salt = Owner::new("salt").unwrap();
        // b belongs to someone else -> whole handoff fails, a untouched
        g.hand_off(&[id("b")], &har, salt.clone(), t0()).unwrap();
        let err = g.hand_off(
            &[id("a"), id("b")],
            &har,
            Owner::new("ansible").unwrap(),
            t0(),
        );
        assert!(matches!(err, Err(Error::HandoffViolation(_))));
        assert_eq!(g.get(&id("a")).unwrap().provenance.owner.as_str(), "har");
        // Valid handoff produces a checkpoint and transfers ownership
        let cp = g.hand_off(&[id("a")], &har, salt.clone(), t0()).unwrap();
        assert_eq!(cp.resources, vec![id("a")]);
        assert_eq!(g.get(&id("a")).unwrap().provenance.owner, salt);
    }

    #[test]
    fn test_partially_realised_handoff() {
        let mut g = graph(&["a", "b"]);
        let har = Owner::new("har").unwrap();
        // a realised, b still declared — both hand off together
        g.advance(&id("a"), RealisationStatus::Planned, t0())
            .unwrap();
        g.advance(&id("a"), RealisationStatus::Realised, t0())
            .unwrap();
        let cp = g
            .hand_off(&[id("a"), id("b")], &har, Owner::new("salt").unwrap(), t0())
            .unwrap();
        assert_eq!(cp.resources.len(), 2);
        // Realisation status survives the transfer (partial estate resumes)
        assert_eq!(
            g.get(&id("a")).unwrap().provenance.status,
            RealisationStatus::Realised
        );
        assert_eq!(
            g.get(&id("b")).unwrap().provenance.status,
            RealisationStatus::Declared
        );
    }
}
