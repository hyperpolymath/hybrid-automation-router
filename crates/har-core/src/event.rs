// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Automation events that flow through the router
//!
//! Events are the primary input to the routing engine. They carry enough
//! context for the router to decide which automation target should handle them.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// An event that needs routing to an automation target
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationEvent {
    /// Unique event identifier
    pub id: String,
    /// When the event was created
    pub timestamp: DateTime<Utc>,
    /// Where the event originated
    pub source: EventSource,
    /// Event priority for routing decisions
    pub priority: EventPriority,
    /// Event category (filesystem, web, api, document, scheduled)
    pub category: String,
    /// Event payload — target-specific data
    pub payload: serde_json::Value,
    /// Optional tags for rule-based routing
    #[serde(default)]
    pub tags: Vec<String>,
    /// Optional target hint (bypass routing, send directly)
    pub target_hint: Option<String>,
}

impl AutomationEvent {
    /// Create a new automation event
    pub fn new(source: EventSource, category: impl Into<String>) -> Self {
        Self {
            id: generate_event_id(),
            timestamp: Utc::now(),
            source,
            priority: EventPriority::Normal,
            category: category.into(),
            payload: serde_json::Value::Null,
            tags: Vec::new(),
            target_hint: None,
        }
    }

    /// Set the event payload
    pub fn with_payload(mut self, payload: serde_json::Value) -> Self {
        self.payload = payload;
        self
    }

    /// Set event priority
    pub fn with_priority(mut self, priority: EventPriority) -> Self {
        self.priority = priority;
        self
    }

    /// Add a routing tag
    pub fn with_tag(mut self, tag: impl Into<String>) -> Self {
        self.tags.push(tag.into());
        self
    }

    /// Set a direct target hint (bypasses routing rules)
    pub fn with_target_hint(mut self, target: impl Into<String>) -> Self {
        self.target_hint = Some(target.into());
        self
    }

    /// Check if this event is compatible with rpa-elysium event format
    pub fn is_rpa_elysium_compatible(&self) -> bool {
        matches!(
            self.category.as_str(),
            "filesystem" | "scheduled" | "manual"
        )
    }
}

/// Where an automation event originated
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EventSource {
    /// Filesystem watcher (rpa-elysium native)
    Filesystem { path: String },
    /// HTTP webhook
    Webhook { endpoint: String },
    /// Message queue (proven-queueconn)
    Queue { queue_name: String },
    /// Scheduled trigger
    Schedule { cron: String },
    /// Manual trigger (CLI or API)
    Manual { user: Option<String> },
    /// Another automation target (chained)
    Chained { source_target: String },
}

/// Event priority levels
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventPriority {
    Low,
    #[default]
    Normal,
    High,
    Critical,
}

fn generate_event_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_event_creation() {
        let event = AutomationEvent::new(
            EventSource::Filesystem {
                path: "/tmp/test".into(),
            },
            "filesystem",
        );
        assert!(!event.id.is_empty());
        assert!(event.is_rpa_elysium_compatible());
    }

    #[test]
    fn test_webhook_not_rpa_compatible() {
        let event = AutomationEvent::new(
            EventSource::Webhook {
                endpoint: "/api/hook".into(),
            },
            "web",
        );
        assert!(!event.is_rpa_elysium_compatible());
    }
}
