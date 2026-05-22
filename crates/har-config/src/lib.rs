// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! HAR Config — Configuration loading and validation for the Hybrid Automation Router
//!
//! Reads JSON configuration files describing router targets, routing rules, and
//! global settings, then converts them into the core types used by the routing engine.
//!
//! # Modules
//!
//! - [`loader`] — Parse and validate `RouterConfig` from JSON files
//! - [`targets`] — Convert `TargetConfig` into [`har_core::AutomationTarget`]
//! - [`rules`] — Tag-based routing rule definitions and conversion

#![forbid(unsafe_code)]
pub mod loader;
pub mod rules;
pub mod targets;

pub use loader::{load_config, RouterConfig, TargetConfig};
pub use rules::RoutingRuleConfig;
pub use targets::build_targets;
