// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Capability verification — the pluggable policy gate on routing.
//!
//! Capability-aware routing has two layers:
//!
//! 1. **Intersection** (always on): a target is only eligible for an event if
//!    it declares every capability the event requires. This is enforced
//!    structurally in the router via [`AutomationTarget::satisfies`].
//! 2. **Verification** (pluggable): an additional policy hook that can veto an
//!    otherwise-eligible (event, target) pairing — e.g. a security policy that
//!    checks the caller is authorised for a privileged capability. The default
//!    [`AllowAll`] verifier vetoes nothing, preserving historical behaviour.
//!
//! Keeping the veto separate from the intersection means the "can this target
//! physically do it?" question (capabilities) stays distinct from the "is this
//! caller allowed to ask?" question (policy).

use crate::event::AutomationEvent;
use crate::target::AutomationTarget;

/// A policy gate deciding whether a target may handle an event, beyond the
/// structural capability intersection the router already enforces.
pub trait CapabilityVerifier: Send + Sync {
    /// Return `true` if `target` is permitted to handle `event`.
    ///
    /// Implementations may assume the router has already checked that `target`
    /// [`satisfies`](AutomationTarget::satisfies) `event.required_capabilities`
    /// and is available — this hook is for *additional* policy, not for
    /// re-doing the intersection.
    fn verify(&self, event: &AutomationEvent, target: &AutomationTarget) -> bool;

    /// A short name for logging / decision provenance.
    fn name(&self) -> &str {
        "capability-verifier"
    }
}

/// The default verifier: permits every pairing. Capability-aware routing with
/// `AllowAll` behaves exactly like the historical category-only routing plus
/// the (always-on) required-capability intersection.
#[derive(Debug, Default, Clone, Copy)]
pub struct AllowAll;

impl CapabilityVerifier for AllowAll {
    fn verify(&self, _event: &AutomationEvent, _target: &AutomationTarget) -> bool {
        true
    }

    fn name(&self) -> &str {
        "allow-all"
    }
}

/// A verifier that additionally re-asserts the capability intersection. Useful
/// as a belt-and-braces policy, or as a worked example of a non-trivial
/// verifier: it rejects any target that does not declare every required
/// capability (which the router already filters, so this only bites if a
/// caller invokes the verifier directly).
#[derive(Debug, Default, Clone, Copy)]
pub struct RequireDeclaredCapabilities;

impl CapabilityVerifier for RequireDeclaredCapabilities {
    fn verify(&self, event: &AutomationEvent, target: &AutomationTarget) -> bool {
        target.satisfies(&event.required_capabilities)
    }

    fn name(&self) -> &str {
        "require-declared-capabilities"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{AutomationEvent, EventSource};
    use crate::target::{AutomationTarget, TargetCapability};

    fn fs_event_requiring(caps: &[TargetCapability]) -> AutomationEvent {
        let mut e = AutomationEvent::new(
            EventSource::Filesystem {
                path: "/tmp/x".into(),
            },
            "filesystem",
        );
        for &c in caps {
            e = e.requiring(c);
        }
        e
    }

    #[test]
    fn allow_all_permits_everything() {
        let e = fs_event_requiring(&[TargetCapability::Ocr]);
        let t = AutomationTarget::new("t", "T", "q"); // declares nothing
        assert!(AllowAll.verify(&e, &t));
    }

    #[test]
    fn require_declared_enforces_the_intersection() {
        let e = fs_event_requiring(&[TargetCapability::Filesystem, TargetCapability::Plugin]);

        let ok = AutomationTarget::new("ok", "OK", "q")
            .with_capability(TargetCapability::Filesystem)
            .with_capability(TargetCapability::Plugin);
        assert!(RequireDeclaredCapabilities.verify(&e, &ok));

        let missing =
            AutomationTarget::new("no", "NO", "q").with_capability(TargetCapability::Filesystem); // no Plugin
        assert!(!RequireDeclaredCapabilities.verify(&e, &missing));
    }
}
