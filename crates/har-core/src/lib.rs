// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! HAR Core — Foundation types for the Hybrid Automation Router
//!
//! Defines the shared vocabulary between HAR and its automation targets
//! (rpa-elysium, web automation, API integration, etc.).
//!
//! # Key Types
//!
//! - [`AutomationEvent`] — An event that needs routing to an automation target
//! - [`RouteDecision`] — The router's decision about where to send an event
//! - [`AutomationTarget`] — A registered automation endpoint
//! - [`RoutingContext`] — Contextual information for making routing decisions

#![forbid(unsafe_code)]
pub mod error;
pub mod event;
pub mod route;
pub mod target;
pub mod verify;

/// The shared queue ABI (tags + `RoutedEnvelope` codec) — re-exported from the
/// standalone, vendorable `har-abi` crate so `har_core::abi::*` keeps working
/// while the ABI itself lives in the separate shared artifact.
pub use har_abi as abi;

pub use error::{Error, Result};
pub use event::{AutomationEvent, EventPriority, EventSource};
pub use har_abi::{DeliveryGuarantee, MessageState, QueueError, QueueOp, QueueState, ABI_VERSION};
pub use route::{RouteDecision, RoutingContext, RoutingStrategy};
pub use target::{AutomationTarget, TargetCapability, TargetStatus};
pub use verify::{AllowAll, CapabilityVerifier, RequireDeclaredCapabilities};
