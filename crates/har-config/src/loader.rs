// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Configuration loader — parse and validate router configuration from JSON files
//!
//! The primary entry point is [`load_config`], which reads a JSON file from disk,
//! deserialises it into a [`RouterConfig`], and validates the result. Error messages
//! include the file path and, where possible, the JSON line/column of the problem.

use crate::rules::RoutingRuleConfig;
use serde::{Deserialize, Serialize};
use std::path::Path;
use tracing::info;

/// Top-level router configuration
///
/// Describes all targets the router can dispatch to, the routing rules that
/// govern event-to-target matching, and global settings such as the default
/// strategy and health-check interval.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouterConfig {
    /// Human-readable name for this router instance
    pub name: String,

    /// Automation targets the router can dispatch events to
    pub targets: Vec<TargetConfig>,

    /// Tag-based routing rules evaluated in priority order
    #[serde(default)]
    pub rules: Vec<RoutingRuleConfig>,

    /// Default routing strategy when no rule matches
    /// (e.g. "capability_match", "round_robin", "weighted_random")
    #[serde(default = "default_strategy")]
    pub default_strategy: String,

    /// Interval in milliseconds between target health checks
    #[serde(default = "default_health_check_interval")]
    pub health_check_interval_ms: u64,
}

/// Configuration for a single automation target
///
/// This is the serialisable representation read from config files. Use
/// [`crate::targets::build_targets`] to convert a slice of these into
/// [`har_core::AutomationTarget`] instances ready for the routing engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetConfig {
    /// Unique identifier (must be unique across all targets)
    pub id: String,

    /// Human-readable display name
    pub name: String,

    /// Connection endpoint (queue name, URL, socket path, etc.)
    pub endpoint: String,

    /// Communication protocol: "queue", "http", "unix_socket", "in_process"
    pub protocol: String,

    /// List of capability strings this target supports
    /// (e.g. "filesystem", "web", "api", "document", "email")
    #[serde(default)]
    pub capabilities: Vec<String>,

    /// Delivery guarantee: "at_most_once", "at_least_once", "exactly_once"
    #[serde(default = "default_delivery_guarantee")]
    pub delivery_guarantee: String,

    /// Priority weight (higher = preferred when multiple targets match)
    #[serde(default = "default_weight")]
    pub weight: u32,

    /// Whether this target is enabled for routing
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

// ---------------------------------------------------------------------------
// Default value helpers
// ---------------------------------------------------------------------------

fn default_strategy() -> String {
    "capability_match".to_string()
}

fn default_health_check_interval() -> u64 {
    30_000
}

fn default_delivery_guarantee() -> String {
    "at_least_once".to_string()
}

fn default_weight() -> u32 {
    100
}

fn default_enabled() -> bool {
    true
}

// ---------------------------------------------------------------------------
// Loading and validation
// ---------------------------------------------------------------------------

/// Load a [`RouterConfig`] from a JSON file at `path`.
///
/// Returns a descriptive error on I/O failure or JSON parse failure, including
/// the file path and (for parse errors) the line/column of the problem.
///
/// After deserialisation the config is validated — duplicate target IDs and
/// unknown protocol strings are rejected.
pub fn load_config(path: impl AsRef<Path>) -> har_core::Result<RouterConfig> {
    let path = path.as_ref();
    info!(path = %path.display(), "Loading router configuration");

    let contents = std::fs::read_to_string(path).map_err(|err| {
        har_core::Error::Config(format!(
            "Failed to read config file '{}': {}",
            path.display(),
            err
        ))
    })?;

    let config: RouterConfig = serde_json::from_str(&contents).map_err(|err| {
        let location = format!("line {}, column {}", err.line(), err.column());
        har_core::Error::Config(format!(
            "Invalid JSON in '{}' at {}: {}",
            path.display(),
            location,
            err
        ))
    })?;

    validate_config(&config, path)?;

    info!(
        name = %config.name,
        targets = config.targets.len(),
        rules = config.rules.len(),
        "Router configuration loaded successfully"
    );

    Ok(config)
}

/// Validate internal consistency of a loaded [`RouterConfig`].
fn validate_config(config: &RouterConfig, path: &Path) -> har_core::Result<()> {
    // Check for duplicate target IDs
    let mut seen_ids = std::collections::HashSet::new();
    for target in &config.targets {
        if !seen_ids.insert(&target.id) {
            return Err(har_core::Error::Config(format!(
                "Duplicate target ID '{}' in '{}'",
                target.id,
                path.display()
            )));
        }
    }

    // Validate protocol strings
    let valid_protocols = ["queue", "http", "unix_socket", "in_process"];
    for target in &config.targets {
        if !valid_protocols.contains(&target.protocol.as_str()) {
            return Err(har_core::Error::Config(format!(
                "Unknown protocol '{}' for target '{}' in '{}'. \
                 Valid protocols: {}",
                target.protocol,
                target.id,
                path.display(),
                valid_protocols.join(", ")
            )));
        }
    }

    // Validate delivery guarantee strings
    let valid_guarantees = ["at_most_once", "at_least_once", "exactly_once"];
    for target in &config.targets {
        if !valid_guarantees.contains(&target.delivery_guarantee.as_str()) {
            return Err(har_core::Error::Config(format!(
                "Unknown delivery guarantee '{}' for target '{}' in '{}'. \
                 Valid guarantees: {}",
                target.delivery_guarantee,
                target.id,
                path.display(),
                valid_guarantees.join(", ")
            )));
        }
    }

    // Validate that routing rules reference existing target IDs
    for rule in &config.rules {
        for target_id in &rule.target_ids {
            if !seen_ids.contains(target_id) {
                return Err(har_core::Error::Config(format!(
                    "Routing rule '{}' references unknown target '{}' in '{}'",
                    rule.name,
                    target_id,
                    path.display()
                )));
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    /// Helper: write JSON to a temp file, return the path
    fn write_temp_json(json: &str) -> NamedTempFile {
        let mut file = NamedTempFile::new().expect("Failed to create temp file");
        file.write_all(json.as_bytes())
            .expect("Failed to write temp file");
        file
    }

    #[test]
    fn test_load_json() {
        let json = r#"{
            "name": "test-router",
            "targets": [
                {
                    "id": "rpa-elysium",
                    "name": "RPA Elysium",
                    "endpoint": "amqp://localhost/rpa-tasks",
                    "protocol": "queue",
                    "capabilities": ["filesystem", "scheduled"],
                    "delivery_guarantee": "at_least_once",
                    "weight": 150,
                    "enabled": true
                }
            ],
            "rules": [
                {
                    "name": "fs-to-rpa",
                    "tags": ["filesystem"],
                    "target_ids": ["rpa-elysium"],
                    "priority": 10,
                    "enabled": true
                }
            ],
            "default_strategy": "capability_match",
            "health_check_interval_ms": 15000
        }"#;

        let file = write_temp_json(json);
        let config = load_config(file.path()).expect("Config should load successfully");

        assert_eq!(config.name, "test-router");
        assert_eq!(config.targets.len(), 1);
        assert_eq!(config.targets[0].id, "rpa-elysium");
        assert_eq!(config.targets[0].weight, 150);
        assert_eq!(config.rules.len(), 1);
        assert_eq!(config.rules[0].name, "fs-to-rpa");
        assert_eq!(config.default_strategy, "capability_match");
        assert_eq!(config.health_check_interval_ms, 15000);
    }

    #[test]
    fn test_default_values() {
        let json = r#"{
            "name": "minimal-router",
            "targets": [
                {
                    "id": "basic",
                    "name": "Basic Target",
                    "endpoint": "http://localhost:8080",
                    "protocol": "http"
                }
            ]
        }"#;

        let file = write_temp_json(json);
        let config = load_config(file.path()).expect("Config should load successfully");

        assert_eq!(config.default_strategy, "capability_match");
        assert_eq!(config.health_check_interval_ms, 30_000);
        assert!(config.rules.is_empty());

        let target = &config.targets[0];
        assert_eq!(target.delivery_guarantee, "at_least_once");
        assert_eq!(target.weight, 100);
        assert!(target.enabled);
        assert!(target.capabilities.is_empty());
    }

    #[test]
    fn test_load_invalid_json() {
        let file = write_temp_json("{ not valid json }");
        let err = load_config(file.path()).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("line"), "Error should mention line: {msg}");
        assert!(msg.contains("column"), "Error should mention column: {msg}");
    }

    #[test]
    fn test_load_duplicate_target_ids() {
        let json = r#"{
            "name": "dup-test",
            "targets": [
                { "id": "dup", "name": "A", "endpoint": "a", "protocol": "http" },
                { "id": "dup", "name": "B", "endpoint": "b", "protocol": "http" }
            ]
        }"#;

        let file = write_temp_json(json);
        let err = load_config(file.path()).unwrap_err();
        assert!(
            err.to_string().contains("Duplicate target ID"),
            "Expected duplicate ID error: {err}"
        );
    }

    #[test]
    fn test_load_unknown_protocol() {
        let json = r#"{
            "name": "bad-proto",
            "targets": [
                { "id": "x", "name": "X", "endpoint": "x", "protocol": "smoke_signal" }
            ]
        }"#;

        let file = write_temp_json(json);
        let err = load_config(file.path()).unwrap_err();
        assert!(
            err.to_string().contains("Unknown protocol"),
            "Expected protocol error: {err}"
        );
    }
}
