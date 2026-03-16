// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! Routing rules — tag-based event-to-target mapping
//!
//! Rules are the simplest routing mechanism: events carrying certain tags are
//! dispatched to specific target IDs. Rules are evaluated in priority order
//! (lower number = higher priority) and only enabled rules participate.

use har_core::route::RoutingContext;
use serde::{Deserialize, Serialize};
use tracing::debug;

/// A tag-based routing rule read from configuration
///
/// When an event's tags intersect with a rule's [`tags`](RoutingRuleConfig::tags),
/// the event is eligible for dispatch to any of the rule's
/// [`target_ids`](RoutingRuleConfig::target_ids).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoutingRuleConfig {
    /// Human-readable rule name (for logging and diagnostics)
    pub name: String,

    /// Tags that this rule matches against — an event must carry at least one
    /// of these tags for the rule to apply
    pub tags: Vec<String>,

    /// Target IDs that matching events should be routed to
    pub target_ids: Vec<String>,

    /// Priority (lower number = evaluated first). Defaults to 100.
    #[serde(default = "default_priority")]
    pub priority: u32,

    /// Whether this rule is active. Defaults to true.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_priority() -> u32 {
    100
}

fn default_enabled() -> bool {
    true
}

/// Apply a set of routing rules to a [`RoutingContext`], populating its
/// `tag_rules` map.
///
/// Rules are sorted by priority (ascending — lower number first) before being
/// applied. Disabled rules are skipped entirely.
pub fn apply_rules(rules: &[RoutingRuleConfig], ctx: &mut RoutingContext) {
    let mut sorted: Vec<&RoutingRuleConfig> = rules.iter().collect();
    sorted.sort_by_key(|r| r.priority);

    for rule in sorted {
        if !rule.enabled {
            debug!(rule = %rule.name, "Skipping disabled routing rule");
            continue;
        }

        for tag in &rule.tags {
            for target_id in &rule.target_ids {
                ctx.add_tag_rule(tag.clone(), target_id.clone());
            }
        }

        debug!(
            rule = %rule.name,
            tags = ?rule.tags,
            targets = ?rule.target_ids,
            priority = rule.priority,
            "Applied routing rule"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create a simple rule
    fn make_rule(name: &str, tags: &[&str], targets: &[&str], priority: u32) -> RoutingRuleConfig {
        RoutingRuleConfig {
            name: name.to_string(),
            tags: tags.iter().map(|s| s.to_string()).collect(),
            target_ids: targets.iter().map(|s| s.to_string()).collect(),
            priority,
            enabled: true,
        }
    }

    #[test]
    fn test_routing_rules() {
        let rules = vec![
            make_rule("fs-to-rpa", &["filesystem"], &["rpa-elysium"], 10),
            make_rule("web-to-browser", &["web", "api"], &["web-auto"], 20),
        ];

        let mut ctx = RoutingContext::new();
        apply_rules(&rules, &mut ctx);

        // "filesystem" tag should route to rpa-elysium
        assert!(ctx.tag_rules.contains_key("filesystem"));
        assert_eq!(ctx.tag_rules["filesystem"], vec!["rpa-elysium"]);

        // "web" tag should route to web-auto
        assert!(ctx.tag_rules.contains_key("web"));
        assert_eq!(ctx.tag_rules["web"], vec!["web-auto"]);

        // "api" tag should also route to web-auto
        assert!(ctx.tag_rules.contains_key("api"));
        assert_eq!(ctx.tag_rules["api"], vec!["web-auto"]);
    }

    #[test]
    fn test_disabled_rules_skipped() {
        let mut rule = make_rule("disabled", &["filesystem"], &["rpa"], 1);
        rule.enabled = false;

        let mut ctx = RoutingContext::new();
        apply_rules(&[rule], &mut ctx);

        assert!(
            ctx.tag_rules.is_empty(),
            "Disabled rules should not add tag entries"
        );
    }

    #[test]
    fn test_rules_sorted_by_priority() {
        // Both rules map the same tag to different targets.
        // Priority order determines insertion order in the tag_rules vec.
        let rules = vec![
            make_rule("low-pri", &["shared"], &["fallback"], 200),
            make_rule("high-pri", &["shared"], &["primary"], 10),
        ];

        let mut ctx = RoutingContext::new();
        apply_rules(&rules, &mut ctx);

        let targets = &ctx.tag_rules["shared"];
        // high-pri (10) should be applied before low-pri (200)
        assert_eq!(targets[0], "primary");
        assert_eq!(targets[1], "fallback");
    }

    #[test]
    fn test_default_values() {
        let json = r#"{
            "name": "minimal",
            "tags": ["test"],
            "target_ids": ["t1"]
        }"#;

        let rule: RoutingRuleConfig =
            serde_json::from_str(json).expect("Should deserialise with defaults");
        assert_eq!(rule.priority, 100);
        assert!(rule.enabled);
    }
}
