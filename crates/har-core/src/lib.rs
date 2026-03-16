// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

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

pub use error::{Error, Result};
pub use event::{AutomationEvent, EventPriority, EventSource};
pub use route::{RouteDecision, RoutingContext, RoutingStrategy};
pub use target::{AutomationTarget, TargetCapability, TargetStatus};
