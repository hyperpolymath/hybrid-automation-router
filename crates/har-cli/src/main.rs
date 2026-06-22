// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

//! HAR CLI — Command-line interface for the Hybrid Automation Router

#![forbid(unsafe_code)]
use clap::{Parser, Subcommand};
use har_core::{AutomationEvent, AutomationTarget, EventSource, TargetStatus};
use har_router::Router;
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

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List registered automation targets
    Targets,

    /// Route a test event and show the decision
    Route {
        /// Event category (filesystem, web, api, document, etc.)
        category: String,
        /// Optional target hint
        #[arg(long)]
        target: Option<String>,
    },

    /// Show router status
    Status,
}

fn main() {
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

    let router = setup_default_router();

    match cli.command {
        Commands::Targets => show_targets(&router),
        Commands::Route { category, target } => route_test_event(&router, &category, target),
        Commands::Status => show_status(&router),
    }
}

/// Set up a router with default targets (demonstrates rpa-elysium integration)
fn setup_default_router() -> Router {
    let mut router = Router::new();

    // Register rpa-elysium as the filesystem automation target
    let mut rpa = AutomationTarget::rpa_elysium("rpa-elysium-queue");
    rpa.status = TargetStatus::Healthy;
    router.register_target(rpa);

    // Tag-based routing rules
    router.add_tag_rule("filesystem", "rpa-elysium");
    router.add_tag_rule("backup", "rpa-elysium");
    router.add_tag_rule("archive", "rpa-elysium");

    router
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

fn route_test_event(router: &Router, category: &str, target_hint: Option<String>) {
    let mut event = AutomationEvent::new(EventSource::Manual { user: None }, category);

    if let Some(hint) = target_hint {
        event = event.with_target_hint(hint);
    }

    match router.route(&event) {
        Ok(decision) => {
            info!("Route decision:");
            info!("  Target: {}", decision.target_id);
            info!("  Strategy: {:?}", decision.strategy);
            info!("  Confidence: {:.0}%", decision.confidence * 100.0);
            info!("  Reason: {}", decision.reason);
            if !decision.alternatives.is_empty() {
                info!("  Alternatives: {:?}", decision.alternatives);
            }
        }
        Err(e) => {
            info!("No route found: {}", e);
        }
    }
}

fn show_status(router: &Router) {
    let total = router.targets().len();
    let healthy = router.targets().iter().filter(|t| t.is_available()).count();

    info!("Router status:");
    info!("  Total targets: {}", total);
    info!("  Available: {}", healthy);
    info!("  Unavailable: {}", total - healthy);
}
