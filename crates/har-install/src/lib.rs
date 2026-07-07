// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! HAR Install — tier 1 of the install-domain subsumption ladder (ADR-0003).
//!
//! The first concrete resource domain of the automation interlingua (ADR-0002)
//! is software installation, captured as a five-tier ladder in a fixed,
//! owner-directed order: least-structured first, incumbents last. This crate
//! is **tier 1** — the package-manager-less end: `curl | sh` scripts,
//! hand-placed tarballs, `configure && make && make install`, single-binary
//! drops, AppImages, and `git clone` + symlink arrangements.
//!
//! These have no manager, no registry, no recorded footprint, no uninstall,
//! and usually no integrity check. This crate defines the domain's core
//! schema *from first principles* (there is no incumbent interface to conform
//! to) and makes the unmanageable **auditable, uninstallable, and
//! reinstallable**:
//!
//! - [`InstallArtifact`] — the tier-1 resource: [`origin`](InstallOrigin),
//!   [`method`](InstallMethod), [`integrity`](Integrity),
//!   [`footprint`](Footprint), derived uninstall inverse, and re-run/upgrade
//!   [`policy`](RerunPolicy).
//! - [`mod@capture`] — run an opaque install behind an [`Executor`], capture
//!   its footprint, then uninstall and reinstall *from the record alone* (the
//!   ROADMAP Phase 2C tier-1 gate, issue #97).
//! - [`mapping`] — lower/lift between an artifact and a `pkg.install`
//!   [`har_meta::Resource`]. Tier 2 must specialise this schema without
//!   redesigning it; the round-trip is the regression contract.
//! - [`corpus`] — the flagship prover/solver/toolchain survey (issue #106),
//!   executable data rather than prose.
//!
//! HAR fit: install operations route as automation events, providers are
//! automation targets, and exactly-once delivery is the "no double-install"
//! guarantee. The normative meta-model reference is `src/abi/MetaModel.idr`.

#![forbid(unsafe_code)]

pub mod artifact;
pub mod capture;
pub mod corpus;
pub mod error;
pub mod footprint;
pub mod integrity;
pub mod mapping;
pub mod origin;
pub mod rerun;

pub use artifact::{InstallArtifact, InstallMethod};
pub use capture::{
    capture, reinstall, uninstall, Executor, FootprintStrategy, InstallSpec, SimulatedExecutor,
};
pub use error::{Error, Result};
pub use footprint::{Footprint, FootprintSource, PathKind, PlacedPath, RemoveStep};
pub use integrity::Integrity;
pub use mapping::{from_resource, to_resource};
pub use origin::InstallOrigin;
pub use rerun::{RerunPolicy, VersionSpec};
