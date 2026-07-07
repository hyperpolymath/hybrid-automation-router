// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! ROADMAP Phase 2C, tier-1 gate (issue #97):
//! a `curl | sh`-style install is captured, uninstalled, and reinstalled
//! idempotently **from the record alone**.
//!
//! The whole cycle runs against real files under a throwaway root via
//! [`SimulatedExecutor`] — no network, no privilege — so the guarantee is
//! exercised, not merely asserted about data.

use har_install::capture::{capture, reinstall, uninstall, FootprintStrategy, InstallSpec};
use har_install::{
    Executor, InstallMethod, InstallOrigin, Integrity, PlacedPath, RerunPolicy, SimulatedExecutor,
    VersionSpec,
};

/// A rustup-style `curl | sh` install whose script drops **collateral** the
/// author never declared (`env`, a cache dir). Only tracing sees it.
fn curl_sh_spec() -> InstallSpec {
    InstallSpec {
        id: "rustup".to_string(),
        name: "rustup".to_string(),
        version: VersionSpec::Latest,
        prefix: ".local".to_string(),
        origin: InstallOrigin::ScriptPipe {
            url: "https://sh.rustup.rs".to_string(),
        },
        method: InstallMethod::RunScript,
        integrity: Integrity::None,
        rerun: RerunPolicy::AlwaysReinstall,
        declared_paths: vec![PlacedPath::file("bin/rustup")],
    }
}

#[test]
fn curl_sh_install_captured_uninstalled_reinstalled_idempotently() {
    let mut ex = SimulatedExecutor::with_temp("gate-idempotent")
        .expect("temp root")
        // the undeclared files a real rustup script leaves behind
        .with_collateral(vec![
            PlacedPath::file("rustup/env"),
            PlacedPath::dir("rustup/toolchains"),
        ]);

    // 1. Capture by tracing: the footprint is the *actual* placement, not the
    //    author's under-declaration.
    let record = capture(&curl_sh_spec(), FootprintStrategy::TracedExecution, &mut ex).unwrap();
    assert_eq!(
        record.footprint.paths.len(),
        3,
        "tracing must record the two collateral paths the manifest omitted"
    );
    for p in &record.footprint.paths {
        assert!(ex.exists(&record.prefix, &p.path), "placed: {}", p.path);
    }

    // 2. Uninstall from the record alone: every recorded path is gone.
    uninstall(&record, &mut ex).unwrap();
    for p in &record.footprint.paths {
        assert!(
            !ex.exists(&record.prefix, &p.path),
            "still present after uninstall: {}",
            p.path
        );
    }

    // 3. Reinstall from the record alone, and idempotently again.
    let fp1 = reinstall(&record, &mut ex).unwrap();
    let fp2 = reinstall(&record, &mut ex).unwrap();
    assert_eq!(fp1, record.footprint, "reinstall reproduces the record");
    assert_eq!(fp2, fp1, "second reinstall is idempotent");
    for p in &record.footprint.paths {
        assert!(ex.exists(&record.prefix, &p.path), "restored: {}", p.path);
    }
}

#[test]
fn declared_manifest_misses_collateral_that_tracing_catches() {
    // Same install, both strategies, side by side: the concrete evaluation
    // issue #97 asks for.
    let spec = curl_sh_spec();

    let mut traced = SimulatedExecutor::with_temp("gate-traced")
        .unwrap()
        .with_collateral(vec![PlacedPath::file("rustup/env")]);
    let traced_rec = capture(&spec, FootprintStrategy::TracedExecution, &mut traced).unwrap();

    let mut declared = SimulatedExecutor::with_temp("gate-declared")
        .unwrap()
        .with_collateral(vec![PlacedPath::file("rustup/env")]);
    let declared_rec = capture(&spec, FootprintStrategy::DeclaredManifest, &mut declared).unwrap();

    // The declared manifest leaks the collateral file; tracing reclaims it for
    // a complete uninstall.
    assert_eq!(declared_rec.footprint.paths.len(), 1);
    assert_eq!(traced_rec.footprint.paths.len(), 2);

    // Uninstall by the declared record leaves the collateral orphaned...
    uninstall(&declared_rec, &mut declared).unwrap();
    assert!(
        declared.exists(&declared_rec.prefix, "rustup/env"),
        "declared-manifest uninstall orphans the undeclared file"
    );
    // ...whereas the traced record removes everything.
    uninstall(&traced_rec, &mut traced).unwrap();
    assert!(!traced.exists(&traced_rec.prefix, "rustup/env"));
}
