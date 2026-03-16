// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Target conversion — transform [`TargetConfig`] into [`har_core::AutomationTarget`]
//!
//! The configuration layer uses plain strings for protocols and capabilities so
//! that config files remain human-editable. This module maps those strings to the
//! strongly-typed enums defined in `har_core`.

use crate::loader::TargetConfig;
use har_core::target::{AutomationTarget, TargetCapability, TargetProtocol, TargetStatus};
use tracing::warn;

/// Convert a slice of [`TargetConfig`] into a vector of [`AutomationTarget`].
///
/// Disabled targets (`enabled: false`) are converted with [`TargetStatus::Disabled`]
/// so the router knows not to route events to them but can still display them in
/// status listings.
///
/// Unknown capability strings are logged as warnings and skipped rather than
/// causing a hard failure; this keeps the router running even when a config
/// references a capability that hasn't been compiled in yet.
pub fn build_targets(configs: &[TargetConfig]) -> Vec<AutomationTarget> {
    configs.iter().map(build_single_target).collect()
}

/// Convert one [`TargetConfig`] into an [`AutomationTarget`].
fn build_single_target(cfg: &TargetConfig) -> AutomationTarget {
    let protocol = parse_protocol(&cfg.protocol);
    let capabilities: Vec<TargetCapability> = cfg
        .capabilities
        .iter()
        .filter_map(|s| parse_capability(s, &cfg.id))
        .collect();

    let status = if cfg.enabled {
        TargetStatus::Unknown
    } else {
        TargetStatus::Disabled
    };

    AutomationTarget {
        id: cfg.id.clone(),
        name: cfg.name.clone(),
        endpoint: cfg.endpoint.clone(),
        protocol,
        capabilities,
        status,
        weight: cfg.weight,
    }
}

/// Map a protocol string from config to [`TargetProtocol`].
///
/// Defaults to [`TargetProtocol::Queue`] if the string is unrecognised (the
/// loader validates protocol strings, so this fallback only fires for
/// programmatically-constructed configs).
fn parse_protocol(s: &str) -> TargetProtocol {
    match s {
        "queue" => TargetProtocol::Queue,
        "http" => TargetProtocol::Http,
        "unix_socket" => TargetProtocol::UnixSocket,
        "in_process" => TargetProtocol::InProcess,
        other => {
            warn!(protocol = other, "Unknown protocol, defaulting to Queue");
            TargetProtocol::Queue
        }
    }
}

/// Map a capability string from config to [`TargetCapability`].
///
/// Returns `None` (with a warning) for unknown capabilities so that config
/// files can reference future capabilities without breaking the current build.
fn parse_capability(s: &str, target_id: &str) -> Option<TargetCapability> {
    match s {
        "filesystem" => Some(TargetCapability::Filesystem),
        "web" | "web_browser" => Some(TargetCapability::WebBrowser),
        "api" | "api_integration" => Some(TargetCapability::ApiIntegration),
        "document" | "document_processing" => Some(TargetCapability::DocumentProcessing),
        "email" => Some(TargetCapability::Email),
        "desktop" | "desktop_gui" => Some(TargetCapability::DesktopGui),
        "scheduled" | "scheduling" => Some(TargetCapability::Scheduling),
        "plugin" => Some(TargetCapability::Plugin),
        "ocr" => Some(TargetCapability::Ocr),
        "nlp" => Some(TargetCapability::Nlp),
        other => {
            warn!(
                capability = other,
                target = target_id,
                "Unknown capability, skipping"
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create a minimal [`TargetConfig`] with sensible defaults
    fn make_target_config(id: &str, protocol: &str, capabilities: Vec<&str>) -> TargetConfig {
        TargetConfig {
            id: id.to_string(),
            name: format!("Target {id}"),
            endpoint: format!("endpoint-{id}"),
            protocol: protocol.to_string(),
            capabilities: capabilities.into_iter().map(String::from).collect(),
            delivery_guarantee: "at_least_once".to_string(),
            weight: 100,
            enabled: true,
        }
    }

    #[test]
    fn test_build_targets() {
        let configs = vec![
            make_target_config("rpa", "queue", vec!["filesystem", "scheduled", "plugin"]),
            make_target_config("web", "http", vec!["web", "api"]),
        ];

        let targets = build_targets(&configs);

        assert_eq!(targets.len(), 2);

        // First target: rpa
        assert_eq!(targets[0].id, "rpa");
        assert_eq!(targets[0].protocol, TargetProtocol::Queue);
        assert_eq!(targets[0].capabilities.len(), 3);
        assert!(targets[0]
            .capabilities
            .contains(&TargetCapability::Filesystem));
        assert!(targets[0]
            .capabilities
            .contains(&TargetCapability::Scheduling));
        assert!(targets[0].capabilities.contains(&TargetCapability::Plugin));
        assert_eq!(targets[0].status, TargetStatus::Unknown);

        // Second target: web
        assert_eq!(targets[1].id, "web");
        assert_eq!(targets[1].protocol, TargetProtocol::Http);
        assert_eq!(targets[1].capabilities.len(), 2);
        assert!(targets[1]
            .capabilities
            .contains(&TargetCapability::WebBrowser));
        assert!(targets[1]
            .capabilities
            .contains(&TargetCapability::ApiIntegration));
    }

    #[test]
    fn test_build_disabled_target() {
        let mut cfg = make_target_config("disabled", "http", vec![]);
        cfg.enabled = false;

        let targets = build_targets(&[cfg]);
        assert_eq!(targets[0].status, TargetStatus::Disabled);
    }

    #[test]
    fn test_unknown_capability_skipped() {
        let cfg = make_target_config("t", "http", vec!["filesystem", "quantum_teleport"]);
        let targets = build_targets(&[cfg]);

        // "quantum_teleport" should be silently skipped
        assert_eq!(targets[0].capabilities.len(), 1);
        assert!(targets[0]
            .capabilities
            .contains(&TargetCapability::Filesystem));
    }

    #[test]
    fn test_protocol_mapping() {
        assert_eq!(parse_protocol("queue"), TargetProtocol::Queue);
        assert_eq!(parse_protocol("http"), TargetProtocol::Http);
        assert_eq!(parse_protocol("unix_socket"), TargetProtocol::UnixSocket);
        assert_eq!(parse_protocol("in_process"), TargetProtocol::InProcess);
        // Unknown falls back to Queue
        assert_eq!(parse_protocol("carrier_pigeon"), TargetProtocol::Queue);
    }
}
