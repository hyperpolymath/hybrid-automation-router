// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! [`InstallArtifact`] — the core tier-1 resource schema.
//!
//! This is the type the whole tier-1 rung of ADR-0003 is built to define: a
//! record of a package-manager-less install rich enough to make it auditable,
//! uninstallable, and reinstallable. It is deliberately shaped by the general
//! problem, not by any incumbent manager — there is no manager to conform to
//! at this rung.
//!
//! An artifact is the *realised* record (it carries a [`Footprint`]); the
//! pre-install declarative intent is an [`crate::capture::InstallSpec`], which
//! `capture` turns into an artifact.

use crate::footprint::Footprint;
use crate::integrity::Integrity;
use crate::origin::InstallOrigin;
use crate::rerun::{RerunPolicy, VersionSpec};
use serde::{Deserialize, Serialize};

/// How the acquired origin is turned into placed files.
///
/// Orthogonal to [`InstallOrigin`] (which says *where from*): a tarball origin
/// is realised by [`InstallMethod::UnpackToPrefix`], a `curl | sh` origin by
/// [`InstallMethod::RunScript`], and so on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum InstallMethod {
    /// Pipe the fetched script to a shell.
    RunScript,
    /// Unpack an archive under the install prefix.
    UnpackToPrefix,
    /// Copy a single binary to its destination.
    PlaceBinary,
    /// `./configure && make && make install` into the prefix.
    BuildFromSource,
    /// `git clone` then arrange symlinks onto `PATH`.
    SymlinkFromClone,
}

impl InstallMethod {
    /// Stable kebab-case tag for the meta-model attribute.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RunScript => "run-script",
            Self::UnpackToPrefix => "unpack-to-prefix",
            Self::PlaceBinary => "place-binary",
            Self::BuildFromSource => "build-from-source",
            Self::SymlinkFromClone => "symlink-from-clone",
        }
    }

    /// Parse the kebab-case tag.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "run-script" => Some(Self::RunScript),
            "unpack-to-prefix" => Some(Self::UnpackToPrefix),
            "place-binary" => Some(Self::PlaceBinary),
            "build-from-source" => Some(Self::BuildFromSource),
            "symlink-from-clone" => Some(Self::SymlinkFromClone),
            _ => None,
        }
    }
}

/// A captured, realised package-manager-less install.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstallArtifact {
    /// Stable id within an inventory (meta-model resource id charset).
    pub id: String,
    /// Human name of the installed thing (e.g. `ripgrep`, `z3`).
    pub name: String,
    /// The version intent it was installed to satisfy.
    pub version: VersionSpec,
    /// Install prefix: the record-relative root the footprint paths hang off.
    pub prefix: String,
    /// Where it came from.
    pub origin: InstallOrigin,
    /// How it was realised.
    pub method: InstallMethod,
    /// Integrity material (often [`Integrity::None`] at this rung).
    pub integrity: Integrity,
    /// What it placed on the host.
    pub footprint: Footprint,
    /// What a reconcile should do to an already-realised copy.
    pub rerun: RerunPolicy,
}

impl InstallArtifact {
    /// Whether this artifact can be reproduced byte-for-byte from its record:
    /// a pinned version and a footprint to replay. Unpinned (`latest`)
    /// artefacts are auditable and uninstallable but not reproducible.
    pub fn is_reproducible(&self) -> bool {
        self.version.is_pinned() && !self.footprint.is_empty()
    }
}
