// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! HAR CLI — Command-line interface for the Hybrid Automation Router
//!
//! Route management over a JSON config file (`list`, `add`, `remove`,
//! `inspect`) plus dry-run routing (`route`) and router `status`. Without
//! `--config` the read-only commands fall back to a built-in demo router
//! (rpa-elysium as the filesystem target); mutating commands require
//! `--config`.

#![forbid(unsafe_code)]
use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use har_config::{load_config, RouterConfig, RoutingRuleConfig, TargetConfig};
use har_core::{AutomationEvent, EventSource, RoutingStrategy, TargetStatus};
use har_router::Router;
use std::path::{Path, PathBuf};
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

#[derive(Parser)]
#[command(
    name = "har",
    about = "Hybrid Automation Router — Intelligent event routing for automation targets",
    version,
    author
)]
struct Cli {
    /// Enable verbose output
    #[arg(short, long, global = true)]
    verbose: bool,

    /// Router configuration file (JSON). Mutating commands require this;
    /// read-only commands fall back to a built-in demo router without it.
    #[arg(short, long, global = true)]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List registered targets and routing rules
    List,

    /// Add a target or routing rule to the config file
    #[command(subcommand)]
    Add(AddCommands),

    /// Remove a target or routing rule from the config file
    #[command(subcommand)]
    Remove(RemoveCommands),

    /// Inspect one target (by id) or rule (by name) in detail
    Inspect {
        /// Target id or rule name
        name: String,
    },

    /// Route a test event and show the decision (dry-run; nothing is dispatched)
    Route {
        /// Event category (filesystem, web, api, document, etc.)
        category: String,
        /// Optional target hint
        #[arg(long)]
        target: Option<String>,
        /// Tags to attach to the test event (repeatable)
        #[arg(long)]
        tag: Vec<String>,
    },

    /// Show router status
    Status,

    /// List registered automation targets (alias kept for compatibility)
    Targets,
}

#[derive(Subcommand)]
enum AddCommands {
    /// Add an automation target
    Target {
        #[arg(long)]
        id: String,
        #[arg(long)]
        name: String,
        /// Connection endpoint (queue name, URL, socket path, …)
        #[arg(long)]
        endpoint: String,
        /// Protocol: queue, http, unix_socket, in_process
        #[arg(long, default_value = "queue")]
        protocol: String,
        /// Comma-separated capability list (e.g. filesystem,web)
        #[arg(long, value_delimiter = ',')]
        capabilities: Vec<String>,
        /// Priority weight (higher = preferred)
        #[arg(long, default_value_t = 100)]
        weight: u32,
    },
    /// Add a tag-based routing rule
    Rule {
        /// Rule name (must be unique)
        #[arg(long)]
        name: String,
        /// Tags the rule matches (repeatable)
        #[arg(long, required = true)]
        tag: Vec<String>,
        /// Target ids matching events route to (repeatable)
        #[arg(long, required = true)]
        target: Vec<String>,
        /// Priority (lower = evaluated first)
        #[arg(long, default_value_t = 100)]
        priority: u32,
    },
}

#[derive(Subcommand)]
enum RemoveCommands {
    /// Remove a target by id (also strips it from rules that reference it)
    Target { id: String },
    /// Remove a routing rule by name
    Rule { name: String },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    let level = if cli.verbose {
        Level::DEBUG
    } else {
        Level::INFO
    };

    FmtSubscriber::builder()
        .with_max_level(level)
        .with_target(false)
        .compact()
        .init();

    match cli.command {
        Commands::List => {
            let config = load_or_demo(cli.config.as_deref())?;
            list_all(&config);
        }
        Commands::Add(cmd) => {
            let path = require_config(cli.config.as_deref())?;
            let mut config = load_or_new(path)?;
            match cmd {
                AddCommands::Target {
                    id,
                    name,
                    endpoint,
                    protocol,
                    capabilities,
                    weight,
                } => {
                    let target = TargetConfig {
                        id,
                        name,
                        endpoint,
                        protocol,
                        capabilities,
                        delivery_guarantee: "at_least_once".to_string(),
                        weight,
                        enabled: true,
                    };
                    add_target(&mut config, target)?;
                }
                AddCommands::Rule {
                    name,
                    tag,
                    target,
                    priority,
                } => {
                    let rule = RoutingRuleConfig {
                        name,
                        tags: tag,
                        target_ids: target,
                        priority,
                        enabled: true,
                    };
                    add_rule(&mut config, rule)?;
                }
            }
            save_config(&config, path)?;
            println!("Saved {}", path.display());
        }
        Commands::Remove(cmd) => {
            let path = require_config(cli.config.as_deref())?;
            let mut config = load_config(path).map_err(|e| anyhow::anyhow!("{e}"))?;
            match cmd {
                RemoveCommands::Target { id } => remove_target(&mut config, &id)?,
                RemoveCommands::Rule { name } => remove_rule(&mut config, &name)?,
            }
            save_config(&config, path)?;
            println!("Saved {}", path.display());
        }
        Commands::Inspect { name } => {
            let config = load_or_demo(cli.config.as_deref())?;
            inspect(&config, &name)?;
        }
        Commands::Route {
            category,
            target,
            tag,
        } => {
            let config = load_or_demo(cli.config.as_deref())?;
            let router = build_router(&config)?;
            route_test_event(&router, &category, target, tag);
        }
        Commands::Status => {
            let config = load_or_demo(cli.config.as_deref())?;
            let router = build_router(&config)?;
            show_status(&router);
        }
        Commands::Targets => {
            let config = load_or_demo(cli.config.as_deref())?;
            let router = build_router(&config)?;
            show_targets(&router);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Config plumbing
// ---------------------------------------------------------------------------

fn require_config(path: Option<&Path>) -> Result<&Path> {
    path.context("this command modifies a config file — pass --config <path>")
}

/// Load the config at `path`, or start a fresh one when the file is absent
/// (so `har --config new.json add target …` bootstraps a config).
fn load_or_new(path: &Path) -> Result<RouterConfig> {
    if path.exists() {
        load_config(path).map_err(|e| anyhow::anyhow!("{e}"))
    } else {
        Ok(RouterConfig {
            name: "har".to_string(),
            targets: Vec::new(),
            rules: Vec::new(),
            default_strategy: "capability_match".to_string(),
            health_check_interval_ms: 30_000,
        })
    }
}

/// Load the config when given, otherwise the built-in demo configuration.
fn load_or_demo(path: Option<&Path>) -> Result<RouterConfig> {
    match path {
        Some(p) => load_config(p).map_err(|e| anyhow::anyhow!("{e}")),
        None => Ok(demo_config()),
    }
}

fn save_config(config: &RouterConfig, path: &Path) -> Result<()> {
    let json = serde_json::to_string_pretty(config)?;
    std::fs::write(path, json + "\n")
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

/// The demo configuration used when no `--config` is given: rpa-elysium as
/// the filesystem automation target, mirroring the original hard-coded setup.
fn demo_config() -> RouterConfig {
    RouterConfig {
        name: "har-demo".to_string(),
        targets: vec![TargetConfig {
            id: "rpa-elysium".to_string(),
            name: "RPA Elysium".to_string(),
            endpoint: "rpa-elysium-queue".to_string(),
            protocol: "queue".to_string(),
            capabilities: vec!["filesystem".to_string(), "document".to_string()],
            delivery_guarantee: "exactly_once".to_string(),
            weight: 100,
            enabled: true,
        }],
        rules: vec![RoutingRuleConfig {
            name: "rpa-filesystem".to_string(),
            tags: vec![
                "filesystem".to_string(),
                "backup".to_string(),
                "archive".to_string(),
            ],
            target_ids: vec!["rpa-elysium".to_string()],
            priority: 100,
            enabled: true,
        }],
        default_strategy: "capability_match".to_string(),
        health_check_interval_ms: 30_000,
    }
}

// ---------------------------------------------------------------------------
// Config mutations (pure on RouterConfig — unit-tested below)
// ---------------------------------------------------------------------------

fn add_target(config: &mut RouterConfig, target: TargetConfig) -> Result<()> {
    if config.targets.iter().any(|t| t.id == target.id) {
        bail!("target id '{}' already exists", target.id);
    }
    println!("Added target '{}' ({})", target.id, target.name);
    config.targets.push(target);
    Ok(())
}

fn add_rule(config: &mut RouterConfig, rule: RoutingRuleConfig) -> Result<()> {
    if config.rules.iter().any(|r| r.name == rule.name) {
        bail!("rule '{}' already exists", rule.name);
    }
    for id in &rule.target_ids {
        if !config.targets.iter().any(|t| t.id == *id) {
            bail!("rule '{}' references unknown target '{}'", rule.name, id);
        }
    }
    println!("Added rule '{}' (tags: {:?})", rule.name, rule.tags);
    config.rules.push(rule);
    Ok(())
}

fn remove_target(config: &mut RouterConfig, id: &str) -> Result<()> {
    let before = config.targets.len();
    config.targets.retain(|t| t.id != id);
    if config.targets.len() == before {
        bail!("no target with id '{id}'");
    }
    // Strip the target from any rules that referenced it; drop rules left empty.
    for rule in &mut config.rules {
        rule.target_ids.retain(|t| t != id);
    }
    let orphaned: Vec<String> = config
        .rules
        .iter()
        .filter(|r| r.target_ids.is_empty())
        .map(|r| r.name.clone())
        .collect();
    config.rules.retain(|r| !r.target_ids.is_empty());
    println!("Removed target '{id}'");
    for name in orphaned {
        println!("Removed rule '{name}' (no targets left)");
    }
    Ok(())
}

fn remove_rule(config: &mut RouterConfig, name: &str) -> Result<()> {
    let before = config.rules.len();
    config.rules.retain(|r| r.name != name);
    if config.rules.len() == before {
        bail!("no rule named '{name}'");
    }
    println!("Removed rule '{name}'");
    Ok(())
}

// ---------------------------------------------------------------------------
// Router construction
// ---------------------------------------------------------------------------

/// Parse a config strategy string into a [`RoutingStrategy`].
fn parse_strategy(s: &str) -> Option<RoutingStrategy> {
    match s {
        "capability_match" => Some(RoutingStrategy::CapabilityMatch),
        "tag_match" => Some(RoutingStrategy::TagMatch),
        "direct" => Some(RoutingStrategy::Direct),
        "round_robin" => Some(RoutingStrategy::RoundRobin),
        "weighted_random" => Some(RoutingStrategy::WeightedRandom),
        "least_loaded" => Some(RoutingStrategy::LeastLoaded),
        "failover" => Some(RoutingStrategy::Failover),
        _ => None,
    }
}

/// Build a live [`Router`] from a [`RouterConfig`]: convert targets, apply
/// enabled rules in priority order (lower first), set the default strategy.
fn build_router(config: &RouterConfig) -> Result<Router> {
    let strategy = parse_strategy(&config.default_strategy).with_context(|| {
        format!(
            "unknown default_strategy '{}' in config",
            config.default_strategy
        )
    })?;
    let mut router = Router::new().with_strategy(strategy);

    for mut target in har_config::build_targets(&config.targets) {
        // Config-loaded targets start healthy; live health checks adjust later.
        target.status = TargetStatus::Healthy;
        router.register_target(target);
    }

    let mut rules: Vec<&RoutingRuleConfig> = config.rules.iter().filter(|r| r.enabled).collect();
    rules.sort_by_key(|r| r.priority);
    for rule in rules {
        for tag in &rule.tags {
            for target_id in &rule.target_ids {
                router.add_tag_rule(tag.clone(), target_id.clone());
            }
        }
    }

    Ok(router)
}

// ---------------------------------------------------------------------------
// Read-only views
// ---------------------------------------------------------------------------

fn list_all(config: &RouterConfig) {
    println!(
        "Router '{}' — {} target(s), {} rule(s)",
        config.name,
        config.targets.len(),
        config.rules.len()
    );
    println!("Targets:");
    for t in &config.targets {
        println!(
            "  {} ({}) — {} via {} — capabilities: {:?}{}",
            t.id,
            t.name,
            t.endpoint,
            t.protocol,
            t.capabilities,
            if t.enabled { "" } else { " [disabled]" }
        );
    }
    println!("Rules (priority asc):");
    let mut rules: Vec<&RoutingRuleConfig> = config.rules.iter().collect();
    rules.sort_by_key(|r| r.priority);
    for r in rules {
        println!(
            "  [{}] {} — tags {:?} -> {:?}{}",
            r.priority,
            r.name,
            r.tags,
            r.target_ids,
            if r.enabled { "" } else { " [disabled]" }
        );
    }
}

fn inspect(config: &RouterConfig, name: &str) -> Result<()> {
    if let Some(t) = config.targets.iter().find(|t| t.id == name) {
        println!("Target '{}'", t.id);
        println!("  name:               {}", t.name);
        println!("  endpoint:           {}", t.endpoint);
        println!("  protocol:           {}", t.protocol);
        println!("  capabilities:       {:?}", t.capabilities);
        println!("  delivery guarantee: {}", t.delivery_guarantee);
        println!("  weight:             {}", t.weight);
        println!("  enabled:            {}", t.enabled);
        let referencing: Vec<&str> = config
            .rules
            .iter()
            .filter(|r| r.target_ids.iter().any(|id| id == name))
            .map(|r| r.name.as_str())
            .collect();
        println!("  referenced by rules: {referencing:?}");
        return Ok(());
    }
    if let Some(r) = config.rules.iter().find(|r| r.name == name) {
        println!("Rule '{}'", r.name);
        println!("  tags:     {:?}", r.tags);
        println!("  targets:  {:?}", r.target_ids);
        println!("  priority: {}", r.priority);
        println!("  enabled:  {}", r.enabled);
        return Ok(());
    }
    bail!("no target id or rule named '{name}'");
}

fn show_targets(router: &Router) {
    info!("Registered automation targets:");
    for target in router.targets() {
        info!(
            "  {} ({}) — {:?} — capabilities: {:?}",
            target.name, target.id, target.status, target.capabilities
        );
    }
}

fn route_test_event(
    router: &Router,
    category: &str,
    target_hint: Option<String>,
    tags: Vec<String>,
) {
    let mut event = AutomationEvent::new(EventSource::Manual { user: None }, category);

    if let Some(hint) = target_hint {
        event = event.with_target_hint(hint);
    }
    for tag in tags {
        event = event.with_tag(tag);
    }

    match router.route(&event) {
        Ok(decision) => {
            println!("Route decision:");
            println!("  Target: {}", decision.target_id);
            println!("  Strategy: {:?}", decision.strategy);
            println!("  Confidence: {:.0}%", decision.confidence * 100.0);
            println!("  Reason: {}", decision.reason);
            if !decision.alternatives.is_empty() {
                println!("  Alternatives: {:?}", decision.alternatives);
            }
        }
        Err(e) => {
            println!("No route found: {e}");
        }
    }
}

fn show_status(router: &Router) {
    let total = router.targets().len();
    let healthy = router.targets().iter().filter(|t| t.is_available()).count();

    println!("Router status:");
    println!("  Total targets: {total}");
    println!("  Available: {healthy}");
    println!("  Unavailable: {}", total - healthy);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(id: &str) -> TargetConfig {
        TargetConfig {
            id: id.to_string(),
            name: id.to_string(),
            endpoint: format!("{id}-q"),
            protocol: "queue".to_string(),
            capabilities: vec!["web".to_string()],
            delivery_guarantee: "at_least_once".to_string(),
            weight: 100,
            enabled: true,
        }
    }

    fn rule(name: &str, tag: &str, target_id: &str) -> RoutingRuleConfig {
        RoutingRuleConfig {
            name: name.to_string(),
            tags: vec![tag.to_string()],
            target_ids: vec![target_id.to_string()],
            priority: 100,
            enabled: true,
        }
    }

    fn empty_config() -> RouterConfig {
        RouterConfig {
            name: "test".to_string(),
            targets: Vec::new(),
            rules: Vec::new(),
            default_strategy: "capability_match".to_string(),
            health_check_interval_ms: 1_000,
        }
    }

    #[test]
    fn parse_strategy_covers_all_variants() {
        for (s, expected) in [
            ("capability_match", RoutingStrategy::CapabilityMatch),
            ("tag_match", RoutingStrategy::TagMatch),
            ("direct", RoutingStrategy::Direct),
            ("round_robin", RoutingStrategy::RoundRobin),
            ("weighted_random", RoutingStrategy::WeightedRandom),
            ("least_loaded", RoutingStrategy::LeastLoaded),
            ("failover", RoutingStrategy::Failover),
        ] {
            assert_eq!(parse_strategy(s), Some(expected));
        }
        assert_eq!(parse_strategy("nonsense"), None);
    }

    #[test]
    fn add_target_rejects_duplicate_id() {
        let mut config = empty_config();
        add_target(&mut config, target("a")).unwrap();
        assert!(add_target(&mut config, target("a")).is_err());
        assert_eq!(config.targets.len(), 1);
    }

    #[test]
    fn add_rule_rejects_unknown_target_and_duplicate_name() {
        let mut config = empty_config();
        assert!(add_rule(&mut config, rule("r1", "t", "ghost")).is_err());
        add_target(&mut config, target("a")).unwrap();
        add_rule(&mut config, rule("r1", "t", "a")).unwrap();
        assert!(add_rule(&mut config, rule("r1", "u", "a")).is_err());
        assert_eq!(config.rules.len(), 1);
    }

    #[test]
    fn remove_target_strips_rule_references_and_orphans() {
        let mut config = empty_config();
        add_target(&mut config, target("a")).unwrap();
        add_target(&mut config, target("b")).unwrap();
        add_rule(&mut config, rule("only-a", "x", "a")).unwrap();
        let mut both = rule("both", "y", "a");
        both.target_ids.push("b".to_string());
        add_rule(&mut config, both).unwrap();

        remove_target(&mut config, "a").unwrap();

        assert_eq!(config.targets.len(), 1);
        // "only-a" lost its last target and is dropped; "both" keeps "b".
        assert_eq!(config.rules.len(), 1);
        assert_eq!(config.rules[0].name, "both");
        assert_eq!(config.rules[0].target_ids, vec!["b".to_string()]);
        assert!(remove_target(&mut config, "a").is_err());
    }

    #[test]
    fn remove_rule_by_name() {
        let mut config = empty_config();
        add_target(&mut config, target("a")).unwrap();
        add_rule(&mut config, rule("r1", "t", "a")).unwrap();
        remove_rule(&mut config, "r1").unwrap();
        assert!(config.rules.is_empty());
        assert!(remove_rule(&mut config, "r1").is_err());
    }

    #[test]
    fn build_router_from_demo_config_routes() {
        let config = demo_config();
        let router = build_router(&config).unwrap();
        assert_eq!(router.targets().len(), 1);

        // Tag rule from the config routes a tagged event.
        let event =
            AutomationEvent::new(EventSource::Manual { user: None }, "unknown").with_tag("backup");
        let decision = router.route(&event).unwrap();
        assert_eq!(decision.target_id, "rpa-elysium");
        assert_eq!(decision.strategy, RoutingStrategy::TagMatch);

        // Capability match still works for the demo target.
        let event = AutomationEvent::new(EventSource::Manual { user: None }, "filesystem");
        assert_eq!(router.route(&event).unwrap().target_id, "rpa-elysium");
    }

    #[test]
    fn build_router_rejects_unknown_strategy() {
        let mut config = demo_config();
        config.default_strategy = "quantum".to_string();
        assert!(build_router(&config).is_err());
    }

    #[test]
    fn config_roundtrip_through_file() {
        let mut config = empty_config();
        add_target(&mut config, target("a")).unwrap();
        add_rule(&mut config, rule("r1", "t", "a")).unwrap();

        let path = std::env::temp_dir().join(format!("har-cli-test-{}.json", std::process::id()));
        save_config(&config, &path).unwrap();
        let loaded = load_config(&path).unwrap();
        std::fs::remove_file(&path).ok();

        assert_eq!(loaded.targets.len(), 1);
        assert_eq!(loaded.rules.len(), 1);
        assert_eq!(loaded.rules[0].name, "r1");
    }
}
