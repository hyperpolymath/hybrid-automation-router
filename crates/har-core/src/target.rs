// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Automation targets — endpoints that can execute automation tasks
//!
//! Targets are registered with the router and describe their capabilities.
//! The router matches events to targets based on capabilities and routing rules.

use serde::{Deserialize, Serialize};

/// A registered automation target
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationTarget {
    /// Unique target identifier
    pub id: String,
    /// Human-readable name
    pub name: String,
    /// What this target can do
    pub capabilities: Vec<TargetCapability>,
    /// Current operational status
    pub status: TargetStatus,
    /// Connection endpoint (e.g., queue name, socket path, HTTP URL)
    pub endpoint: String,
    /// Protocol for communicating with the target
    pub protocol: TargetProtocol,
    /// Priority weight (higher = preferred when multiple targets match)
    pub weight: u32,
}

impl AutomationTarget {
    /// Create a new target with default weight
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        endpoint: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            capabilities: Vec::new(),
            status: TargetStatus::Unknown,
            endpoint: endpoint.into(),
            protocol: TargetProtocol::Queue,
            weight: 100,
        }
    }

    /// Create a target pre-configured for rpa-elysium integration
    pub fn rpa_elysium(endpoint: impl Into<String>) -> Self {
        Self {
            id: "rpa-elysium".into(),
            name: "RPA Elysium Filesystem Automation".into(),
            capabilities: vec![
                TargetCapability::Filesystem,
                TargetCapability::Scheduling,
                TargetCapability::Plugin,
            ],
            status: TargetStatus::Unknown,
            endpoint: endpoint.into(),
            protocol: TargetProtocol::Queue,
            weight: 100,
        }
    }

    /// Add a capability
    pub fn with_capability(mut self, cap: TargetCapability) -> Self {
        self.capabilities.push(cap);
        self
    }

    /// Check if this target can handle a given event category
    pub fn can_handle(&self, category: &str) -> bool {
        self.capabilities
            .iter()
            .any(|cap| cap.matches_category(category))
    }

    /// Check if this target declares every capability in `required`. An empty
    /// requirement is trivially satisfied. This is the capability-intersection
    /// step of capability-aware routing: a target is only eligible for an
    /// event if it `satisfies` that event's `required_capabilities`.
    pub fn satisfies(&self, required: &[TargetCapability]) -> bool {
        required.iter().all(|need| self.capabilities.contains(need))
    }

    /// Check if target is available for routing
    pub fn is_available(&self) -> bool {
        matches!(self.status, TargetStatus::Healthy | TargetStatus::Degraded)
    }
}

/// What an automation target can do
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetCapability {
    /// Filesystem operations (watch, copy, move, archive, etc.)
    Filesystem,
    /// Web browser automation
    WebBrowser,
    /// HTTP API calls
    ApiIntegration,
    /// Document processing (PDF, Excel, etc.)
    DocumentProcessing,
    /// Email send/receive
    Email,
    /// Desktop GUI automation
    DesktopGui,
    /// Scheduled task execution
    Scheduling,
    /// WASM plugin execution
    Plugin,
    /// OCR / image recognition
    Ocr,
    /// Natural language processing
    Nlp,
}

impl TargetCapability {
    /// Check if this capability matches an event category
    pub fn matches_category(&self, category: &str) -> bool {
        matches!(
            (self, category),
            (Self::Filesystem, "filesystem")
                | (Self::WebBrowser, "web")
                | (Self::ApiIntegration, "api")
                | (Self::DocumentProcessing, "document")
                | (Self::Email, "email")
                | (Self::DesktopGui, "desktop")
                | (Self::Scheduling, "scheduled")
                | (Self::Plugin, "plugin")
                | (Self::Ocr, "ocr")
                | (Self::Nlp, "nlp")
        )
    }
}

/// Current status of an automation target
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetStatus {
    /// Target is operating normally
    Healthy,
    /// Target is operational but with reduced capacity
    Degraded,
    /// Target is not responding
    Unhealthy,
    /// Target status has not been checked
    Unknown,
    /// Target is intentionally disabled
    Disabled,
}

/// Protocol for communicating with a target
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TargetProtocol {
    /// Message queue (proven-queueconn compatible)
    Queue,
    /// Unix domain socket
    UnixSocket,
    /// HTTP/HTTPS REST API
    Http,
    /// In-process function call (same Rust binary)
    InProcess,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rpa_elysium_target() {
        let target = AutomationTarget::rpa_elysium("rpa-tasks");
        assert!(target.can_handle("filesystem"));
        assert!(target.can_handle("scheduled"));
        assert!(!target.can_handle("web"));
    }

    #[test]
    fn test_target_availability() {
        let mut target = AutomationTarget::new("test", "Test", "test-endpoint");
        target.status = TargetStatus::Healthy;
        assert!(target.is_available());

        target.status = TargetStatus::Unhealthy;
        assert!(!target.is_available());
    }
}
