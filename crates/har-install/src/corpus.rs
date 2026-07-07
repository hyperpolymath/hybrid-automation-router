// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! The flagship tier-1 corpus: provers, solvers, and language toolchains.
//!
//! ADR-0003's amendment (PR #105) names prover/solver/toolchain centralisation
//! the flagship workload for the early tiers, and issue #106's first
//! deliverable (depth D1) is a *broad survey*: enumerate the install channel of
//! every prover/solver/toolchain the estate uses. This module is that survey,
//! encoded as [`InstallSpec`]s so it is executable data, not prose.
//!
//! Integrity is recorded as [`Integrity::None`] throughout — an honest
//! statement of the acute tier-1 reality: these artefacts ship checksums or
//! signatures on their release pages, but nothing consumes them today. Tier 2
//! (issue #98) is where verification becomes mandatory; recording `None` now
//! marks precisely the gap the ladder closes.
//!
//! The load-bearing structural point (ADR-0003): the toolchain *managers*
//! themselves — rustup, opam, ghcup, elan, juliaup, deno — are `curl | sh`
//! tier-1 artefacts, yet act as mini package managers for their own universe.
//! Capturing them here forces the schema to model "a provider is itself an
//! installed artefact" long before tier 4 formalises providers.

use crate::artifact::InstallMethod;
use crate::capture::InstallSpec;
use crate::footprint::PlacedPath;
use crate::integrity::Integrity;
use crate::origin::InstallOrigin;
use crate::rerun::{RerunPolicy, VersionSpec};

#[allow(clippy::too_many_arguments)]
fn spec(
    id: &str,
    name: &str,
    version: VersionSpec,
    origin: InstallOrigin,
    method: InstallMethod,
    rerun: RerunPolicy,
    declared_paths: Vec<PlacedPath>,
) -> InstallSpec {
    InstallSpec {
        id: id.to_string(),
        name: name.to_string(),
        version,
        prefix: ".local".to_string(),
        origin,
        method,
        integrity: Integrity::None,
        rerun,
        declared_paths,
    }
}

fn script(url: &str) -> InstallOrigin {
    InstallOrigin::ScriptPipe {
        url: url.to_string(),
    }
}

fn tarball(url: &str) -> InstallOrigin {
    InstallOrigin::Tarball {
        url: url.to_string(),
    }
}

fn bin(name: &str) -> Vec<PlacedPath> {
    vec![PlacedPath::file(format!("bin/{name}"))]
}

/// The toolchain managers — themselves `curl | sh` tier-1 installs, then
/// mini package managers for their own ecosystems. Version is `latest` and the
/// policy `always-reinstall`, honestly reflecting how these self-updating
/// installers behave.
pub fn toolchain_managers() -> Vec<InstallSpec> {
    vec![
        spec(
            "rustup",
            "rustup",
            VersionSpec::Latest,
            script("https://sh.rustup.rs"),
            InstallMethod::RunScript,
            RerunPolicy::AlwaysReinstall,
            vec![PlacedPath::file("bin/rustup"), PlacedPath::dir("rustup")],
        ),
        spec(
            "opam",
            "opam",
            VersionSpec::Latest,
            script("https://opam.ocaml.org/install.sh"),
            InstallMethod::RunScript,
            RerunPolicy::AlwaysReinstall,
            bin("opam"),
        ),
        spec(
            "ghcup",
            "ghcup",
            VersionSpec::Latest,
            script("https://get-ghcup.haskell.org"),
            InstallMethod::RunScript,
            RerunPolicy::AlwaysReinstall,
            vec![PlacedPath::file("bin/ghcup"), PlacedPath::dir("ghcup")],
        ),
        spec(
            "elan",
            "elan",
            VersionSpec::Latest,
            script("https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh"),
            InstallMethod::RunScript,
            RerunPolicy::AlwaysReinstall,
            vec![PlacedPath::file("bin/elan"), PlacedPath::dir("elan")],
        ),
        spec(
            "juliaup",
            "juliaup",
            VersionSpec::Latest,
            script("https://install.julialang.org"),
            InstallMethod::RunScript,
            RerunPolicy::AlwaysReinstall,
            bin("juliaup"),
        ),
        spec(
            "deno",
            "deno",
            VersionSpec::Latest,
            script("https://deno.land/install.sh"),
            InstallMethod::RunScript,
            RerunPolicy::AlwaysReinstall,
            bin("deno"),
        ),
        spec(
            "zig",
            "zig",
            VersionSpec::exact("0.13.0"),
            tarball("https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz"),
            InstallMethod::UnpackToPrefix,
            RerunPolicy::IdempotentSkip,
            vec![PlacedPath::dir("opt/zig"), PlacedPath::symlink("bin/zig", "../opt/zig/zig")],
        ),
        spec(
            "gleam",
            "gleam",
            VersionSpec::exact("1.5.1"),
            tarball("https://github.com/gleam-lang/gleam/releases/download/v1.5.1/gleam-v1.5.1-x86_64-unknown-linux-musl.tar.gz"),
            InstallMethod::UnpackToPrefix,
            RerunPolicy::IdempotentSkip,
            bin("gleam"),
        ),
    ]
}

/// SMT/SAT solvers — almost all distributed as GitHub release tarballs or
/// single binaries hand-placed on `PATH` (pure tier 1).
pub fn solvers() -> Vec<InstallSpec> {
    vec![
        spec(
            "z3",
            "z3",
            VersionSpec::exact("4.13.0"),
            tarball("https://github.com/Z3Prover/z3/releases/download/z3-4.13.0/z3-4.13.0-x64-glibc-2.35.zip"),
            InstallMethod::UnpackToPrefix,
            RerunPolicy::IdempotentSkip,
            vec![PlacedPath::dir("opt/z3"), PlacedPath::symlink("bin/z3", "../opt/z3/bin/z3")],
        ),
        spec(
            "cvc5",
            "cvc5",
            VersionSpec::exact("1.2.0"),
            InstallOrigin::BinaryDrop {
                url: "https://github.com/cvc5/cvc5/releases/download/cvc5-1.2.0/cvc5-Linux-x86_64-static".to_string(),
            },
            InstallMethod::PlaceBinary,
            RerunPolicy::IdempotentSkip,
            bin("cvc5"),
        ),
        spec(
            "yices",
            "yices",
            VersionSpec::exact("2.6.4"),
            tarball("https://github.com/SRI-CSL/yices2/releases/download/Yices-2.6.4/yices-2.6.4-x86_64-pc-linux-gnu.tar.gz"),
            InstallMethod::UnpackToPrefix,
            RerunPolicy::IdempotentSkip,
            bin("yices"),
        ),
        spec(
            "kissat",
            "kissat",
            VersionSpec::exact("4.0.1"),
            InstallOrigin::ConfigureMake {
                source_url: "https://github.com/arminbiere/kissat/archive/refs/tags/rel-4.0.1.tar.gz".to_string(),
            },
            InstallMethod::BuildFromSource,
            RerunPolicy::UpgradeOnVersionChange,
            bin("kissat"),
        ),
    ]
}

/// Proof assistants — a mix of source builds and acquisition through a
/// toolchain manager (Lean via elan, Agda from source), each version-sensitive
/// and, today, unrecorded.
pub fn provers() -> Vec<InstallSpec> {
    vec![
        spec(
            "idris2",
            "idris2",
            VersionSpec::exact("0.7.0"),
            InstallOrigin::ConfigureMake {
                source_url: "https://github.com/idris-lang/Idris2/archive/refs/tags/v0.7.0.tar.gz"
                    .to_string(),
            },
            InstallMethod::BuildFromSource,
            RerunPolicy::UpgradeOnVersionChange,
            bin("idris2"),
        ),
        spec(
            "lean",
            "lean",
            VersionSpec::exact("4.12.0"),
            // Acquired *through* elan (itself a tier-1 script install): the
            // provider-is-an-artefact composition ADR-0003 calls load-bearing.
            script("https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh"),
            InstallMethod::RunScript,
            RerunPolicy::UpgradeOnVersionChange,
            bin("lean"),
        ),
        spec(
            "agda",
            "agda",
            VersionSpec::exact("2.6.4.3"),
            InstallOrigin::GitClone {
                repo: "https://github.com/agda/agda.git".to_string(),
                rev: "v2.6.4.3".to_string(),
            },
            InstallMethod::BuildFromSource,
            RerunPolicy::UpgradeOnVersionChange,
            bin("agda"),
        ),
        spec(
            "acl2",
            "acl2",
            VersionSpec::exact("8.5"),
            InstallOrigin::ConfigureMake {
                source_url: "https://github.com/acl2/acl2/archive/refs/tags/8.5.tar.gz".to_string(),
            },
            InstallMethod::BuildFromSource,
            RerunPolicy::UpgradeOnVersionChange,
            bin("acl2"),
        ),
    ]
}

/// The whole flagship corpus: toolchain managers, then solvers, then provers.
pub fn all() -> Vec<InstallSpec> {
    let mut v = toolchain_managers();
    v.extend(solvers());
    v.extend(provers());
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mapping;
    use std::collections::BTreeSet;

    #[test]
    fn corpus_ids_are_unique() {
        let ids: Vec<_> = all().into_iter().map(|s| s.id).collect();
        let uniq: BTreeSet<_> = ids.iter().cloned().collect();
        assert_eq!(ids.len(), uniq.len(), "corpus ids must be unique");
    }

    #[test]
    fn every_spec_id_is_a_valid_resource_id() {
        // If a corpus id were not a legal meta-model identifier, capturing it
        // and mapping to a resource would fail — catch that here.
        for s in all() {
            assert!(
                har_meta::ResourceId::new(&s.id).is_ok(),
                "corpus id `{}` is not a valid resource id",
                s.id
            );
        }
    }

    #[test]
    fn toolchain_managers_are_all_manager_less_origins() {
        // The whole point: these are acquired without a package manager.
        for s in toolchain_managers() {
            let kind = s.origin.kind();
            assert!(
                matches!(kind, "script-pipe" | "tarball" | "binary-drop"),
                "{} should be a manager-less channel, got {kind}",
                s.id
            );
        }
    }

    #[test]
    fn corpus_maps_onto_meta_model() {
        // Build a minimal artifact from each spec's declaration and confirm it
        // absorbs into a resource and lifts back — the schema-absorption gate
        // exercised across the whole flagship corpus.
        use crate::artifact::InstallArtifact;
        use crate::footprint::{Footprint, FootprintSource};
        for s in all() {
            let art = InstallArtifact {
                id: s.id.clone(),
                name: s.name.clone(),
                version: s.version.clone(),
                prefix: s.prefix.clone(),
                origin: s.origin.clone(),
                method: s.method,
                integrity: s.integrity.clone(),
                footprint: Footprint::new(
                    FootprintSource::DeclaredManifest,
                    s.declared_paths.clone(),
                ),
                rerun: s.rerun,
            };
            let r = mapping::to_resource(&art).unwrap();
            assert_eq!(
                mapping::from_resource(&r).unwrap(),
                art,
                "corpus entry {}",
                s.id
            );
        }
    }
}
