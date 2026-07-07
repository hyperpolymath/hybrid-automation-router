// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Capturing a footprint, and replaying it from the record alone.
//!
//! This module turns the tier-1 promise into working code: an opaque install
//! is run behind an [`Executor`], its footprint captured into an
//! [`InstallArtifact`], and thereafter uninstalled and reinstalled *from the
//! record only*. That capture → uninstall → reinstall cycle is the ROADMAP
//! Phase 2C tier-1 gate (issue #97).
//!
//! Two footprint strategies are offered so both can be evaluated, as the issue
//! asks:
//!
//! * [`FootprintStrategy::DeclaredManifest`] trusts the spec author's declared
//!   file list. Exact and cheap for well-behaved artefacts.
//! * [`FootprintStrategy::TracedExecution`] records what the install *actually*
//!   placed. It captures collateral files a manifest never mentions — the
//!   honest footprint of a `curl | sh` script. The [`SimulatedExecutor`] can
//!   be given collateral to demonstrate exactly this gap.
//!
//! The [`Executor`] seam keeps the cycle hermetic: [`SimulatedExecutor`]
//! realises installs as real files under a throwaway root, so the gate
//! exercises genuine filesystem effects with no network and no privilege.

use crate::artifact::{InstallArtifact, InstallMethod};
use crate::error::{Error, Result};
use crate::footprint::{Footprint, FootprintSource, PathKind, PlacedPath, RemoveStep};
use crate::integrity::Integrity;
use crate::origin::InstallOrigin;
use crate::rerun::{RerunPolicy, VersionSpec};
use std::path::{Path, PathBuf};

/// The declarative intent of an install, before it is realised.
///
/// A spec says "ensure `name` at `version` from this origin, by this method".
/// `declared_paths` is the author's best guess at the footprint (used by
/// [`FootprintStrategy::DeclaredManifest`]); tracing may find more.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallSpec {
    /// Stable id within an inventory.
    pub id: String,
    /// Human name.
    pub name: String,
    /// Version intent.
    pub version: VersionSpec,
    /// Install prefix (record-relative root of the footprint).
    pub prefix: String,
    /// Where it comes from.
    pub origin: InstallOrigin,
    /// How it is realised.
    pub method: InstallMethod,
    /// Integrity material, if any.
    pub integrity: Integrity,
    /// Reconcile policy.
    pub rerun: RerunPolicy,
    /// Author-declared footprint.
    pub declared_paths: Vec<PlacedPath>,
}

/// Which footprint-capture strategy to use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FootprintStrategy {
    /// Record the author's declared paths verbatim.
    DeclaredManifest,
    /// Record what the executor actually placed.
    TracedExecution,
}

/// The host abstraction the capture cycle drives.
///
/// Implementors realise installs and replay/remove footprints. The trait is
/// the seam that lets the tier-1 gate run against a hermetic simulator today
/// and a traced/sandboxed real executor later, unchanged.
pub trait Executor {
    /// Realise `spec`'s install, returning every path actually placed. The
    /// returned set may exceed `spec.declared_paths` — that surplus is the
    /// collateral only tracing can see.
    fn install(&mut self, spec: &InstallSpec) -> Result<Vec<PlacedPath>>;

    /// Recreate an exact recorded footprint (reinstall from the record alone).
    fn replay(&mut self, prefix: &str, paths: &[PlacedPath]) -> Result<()>;

    /// Remove recorded paths (the uninstall inverse).
    fn remove(&mut self, prefix: &str, steps: &[RemoveStep]) -> Result<()>;

    /// Whether a record-relative path currently exists under `prefix`.
    fn exists(&self, prefix: &str, path: &str) -> bool;
}

/// Run `spec`'s install behind `executor` and capture it as an artifact.
pub fn capture(
    spec: &InstallSpec,
    strategy: FootprintStrategy,
    executor: &mut dyn Executor,
) -> Result<InstallArtifact> {
    let actual = executor.install(spec)?;
    let footprint = match strategy {
        FootprintStrategy::DeclaredManifest => Footprint::new(
            FootprintSource::DeclaredManifest,
            spec.declared_paths.clone(),
        ),
        FootprintStrategy::TracedExecution => {
            Footprint::new(FootprintSource::TracedExecution, actual)
        }
    };
    Ok(InstallArtifact {
        id: spec.id.clone(),
        name: spec.name.clone(),
        version: spec.version.clone(),
        prefix: spec.prefix.clone(),
        origin: spec.origin.clone(),
        method: spec.method,
        integrity: spec.integrity.clone(),
        footprint,
        rerun: spec.rerun,
    })
}

/// Uninstall an artifact using only its recorded footprint.
pub fn uninstall(art: &InstallArtifact, executor: &mut dyn Executor) -> Result<()> {
    executor.remove(&art.prefix, &art.footprint.uninstall_plan())
}

/// Reinstall an artifact from its record alone, and confirm every recorded
/// path is present afterwards. Returns the realised footprint, which — for a
/// faithful executor — equals the record's own footprint. That equality is
/// the idempotence the tier-1 gate asserts.
pub fn reinstall(art: &InstallArtifact, executor: &mut dyn Executor) -> Result<Footprint> {
    executor.replay(&art.prefix, &art.footprint.paths)?;
    for p in &art.footprint.paths {
        if !executor.exists(&art.prefix, &p.path) {
            return Err(Error::Io {
                path: p.path.clone(),
                message: "path absent after reinstall from record".to_string(),
            });
        }
    }
    Ok(art.footprint.clone())
}

/// A hermetic executor that realises installs as real files under a throwaway
/// root. It has no network and needs no privilege, so the capture cycle can be
/// exercised end-to-end in a unit test.
pub struct SimulatedExecutor {
    root: PathBuf,
    collateral: Vec<PlacedPath>,
    owns_root: bool,
}

impl SimulatedExecutor {
    /// An executor rooted at `root` (the caller owns cleanup).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            collateral: Vec::new(),
            owns_root: false,
        }
    }

    /// An executor rooted at a unique directory under the system temp dir,
    /// cleaned up on drop. `label` disambiguates concurrent tests.
    pub fn with_temp(label: &str) -> std::io::Result<Self> {
        let root =
            std::env::temp_dir().join(format!("har-install-{}-{}", std::process::id(), label));
        std::fs::create_dir_all(&root)?;
        Ok(Self {
            root,
            collateral: Vec::new(),
            owns_root: true,
        })
    }

    /// Add collateral paths the install places *beyond* what a spec declares —
    /// the undeclared files a `curl | sh` script drops. Present in the traced
    /// footprint, absent from a declared manifest.
    pub fn with_collateral(mut self, paths: Vec<PlacedPath>) -> Self {
        self.collateral = paths;
        self
    }

    fn resolve(&self, prefix: &str, path: &str) -> PathBuf {
        self.root.join(prefix).join(path)
    }

    fn place(&self, prefix: &str, p: &PlacedPath) -> Result<()> {
        let full = self.resolve(prefix, &p.path);
        let io = |e: std::io::Error| Error::Io {
            path: p.path.clone(),
            message: e.to_string(),
        };
        match p.kind {
            PathKind::Dir => {
                std::fs::create_dir_all(&full).map_err(io)?;
            }
            PathKind::File => {
                if let Some(parent) = full.parent() {
                    std::fs::create_dir_all(parent).map_err(io)?;
                }
                std::fs::write(&full, b"").map_err(io)?;
            }
            PathKind::Symlink => {
                if let Some(parent) = full.parent() {
                    std::fs::create_dir_all(parent).map_err(io)?;
                }
                let target = p.link_target.clone().unwrap_or_default();
                symlink_or_stub(&target, &full).map_err(io)?;
            }
        }
        Ok(())
    }
}

impl Drop for SimulatedExecutor {
    fn drop(&mut self) {
        if self.owns_root {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}

impl Executor for SimulatedExecutor {
    fn install(&mut self, spec: &InstallSpec) -> Result<Vec<PlacedPath>> {
        let mut placed = Vec::with_capacity(spec.declared_paths.len() + self.collateral.len());
        for p in &spec.declared_paths {
            self.place(&spec.prefix, p)?;
            placed.push(p.clone());
        }
        for p in &self.collateral {
            self.place(&spec.prefix, p)?;
            placed.push(p.clone());
        }
        Ok(placed)
    }

    fn replay(&mut self, prefix: &str, paths: &[PlacedPath]) -> Result<()> {
        for p in paths {
            self.place(prefix, p)?;
        }
        Ok(())
    }

    fn remove(&mut self, prefix: &str, steps: &[RemoveStep]) -> Result<()> {
        for step in steps {
            let full = self.resolve(prefix, &step.path);
            let io = |e: std::io::Error| Error::Io {
                path: step.path.clone(),
                message: e.to_string(),
            };
            if !full.exists() && step.kind != PathKind::Symlink {
                continue; // already gone; removal is idempotent
            }
            match step.kind {
                PathKind::Dir => std::fs::remove_dir(&full).map_err(io)?,
                PathKind::File | PathKind::Symlink => std::fs::remove_file(&full).map_err(io)?,
            }
        }
        Ok(())
    }

    fn exists(&self, prefix: &str, path: &str) -> bool {
        let full = self.resolve(prefix, path);
        full.exists() || full.symlink_metadata().is_ok()
    }
}

#[cfg(unix)]
fn symlink_or_stub(target: &str, link: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(not(unix))]
fn symlink_or_stub(_target: &str, link: &Path) -> std::io::Result<()> {
    // Platforms without cheap symlinks: a regular file stands in so the
    // footprint cycle still round-trips.
    std::fs::write(link, b"")
}
