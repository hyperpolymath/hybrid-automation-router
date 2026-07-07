// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! The footprint: what an install actually placed on the host.
//!
//! Footprint tracking is the load-bearing tier-1 idea (ADR-0003): the
//! manager-less world has no package database, so HAR *is* the database. Once
//! the placed paths are recorded, the artefact becomes uninstallable (the
//! [`Footprint::uninstall_plan`] inverse) and re-installable from the record
//! alone — the capabilities a `curl | sh` install has never had.
//!
//! Paths are stored **record-relative** (POSIX, relative to the install
//! prefix) so a record is host-independent and can be replayed anywhere.
//!
//! Two capture strategies are modelled (issue #97 asks both be evaluated):
//! [`FootprintSource::DeclaredManifest`] trusts a spec author's declared file
//! list, and [`FootprintSource::TracedExecution`] records what an opaque
//! script *actually* touched. The latter catches collateral files a manifest
//! would miss — see `capture.rs` for the demonstration.

use serde::{Deserialize, Serialize};

/// How a footprint was obtained.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FootprintSource {
    /// The paths were declared up front by the spec author. Cheap and exact
    /// for well-behaved artefacts; blind to anything the install does beyond
    /// its declaration.
    DeclaredManifest,
    /// The paths were observed by tracing the install's filesystem effects
    /// (sandboxed/traced execution). Captures collateral the author never
    /// declared — the honest footprint of an opaque `curl | sh` script.
    TracedExecution,
}

impl FootprintSource {
    /// Stable kebab-case tag for the meta-model attribute.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DeclaredManifest => "declared-manifest",
            Self::TracedExecution => "traced-execution",
        }
    }

    /// Parse the kebab-case tag.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "declared-manifest" => Some(Self::DeclaredManifest),
            "traced-execution" => Some(Self::TracedExecution),
            _ => None,
        }
    }
}

/// The filesystem kind of a placed path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PathKind {
    /// A regular file (a binary, a config, a man page).
    File,
    /// A directory created by the install.
    Dir,
    /// A symlink (e.g. a `~/.local/bin` shim into a clone).
    Symlink,
}

impl PathKind {
    /// Stable kebab-case tag.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::File => "file",
            Self::Dir => "dir",
            Self::Symlink => "symlink",
        }
    }

    /// Parse the kebab-case tag.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "file" => Some(Self::File),
            "dir" => Some(Self::Dir),
            "symlink" => Some(Self::Symlink),
            _ => None,
        }
    }
}

/// One path the install placed, plus how to reproduce it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlacedPath {
    /// Record-relative POSIX path under the install prefix.
    pub path: String,
    /// What kind of filesystem object it is.
    pub kind: PathKind,
    /// For a [`PathKind::Symlink`], the link target (record-relative or
    /// absolute as recorded); `None` for files and dirs.
    pub link_target: Option<String>,
}

impl PlacedPath {
    /// A placed regular file.
    pub fn file(path: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            kind: PathKind::File,
            link_target: None,
        }
    }

    /// A placed directory.
    pub fn dir(path: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            kind: PathKind::Dir,
            link_target: None,
        }
    }

    /// A placed symlink at `path` pointing to `target`.
    pub fn symlink(path: impl Into<String>, target: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            kind: PathKind::Symlink,
            link_target: Some(target.into()),
        }
    }
}

/// One step of the derived uninstall: a path to remove.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoveStep {
    /// Record-relative path to remove.
    pub path: String,
    /// Kind of object (dictates rmdir vs unlink).
    pub kind: PathKind,
}

/// The complete set of paths an install placed, in placement order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Footprint {
    /// How the footprint was captured.
    pub source: FootprintSource,
    /// Placed paths, in the order they were created (parents before children).
    pub paths: Vec<PlacedPath>,
}

impl Footprint {
    /// A footprint captured by the given strategy.
    pub fn new(source: FootprintSource, paths: Vec<PlacedPath>) -> Self {
        Self { source, paths }
    }

    /// The derived uninstall inverse: remove every placed path in the reverse
    /// of placement order, so children are removed before their parent
    /// directories. This is the inverse `uninstall` the tier-1 schema promises
    /// (issue #97) and needs no cooperation from the original installer.
    pub fn uninstall_plan(&self) -> Vec<RemoveStep> {
        self.paths
            .iter()
            .rev()
            .map(|p| RemoveStep {
                path: p.path.clone(),
                kind: p.kind,
            })
            .collect()
    }

    /// Whether the footprint records no paths at all.
    pub fn is_empty(&self) -> bool {
        self.paths.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uninstall_reverses_placement_order() {
        let fp = Footprint::new(
            FootprintSource::TracedExecution,
            vec![
                PlacedPath::dir("opt/tool"),
                PlacedPath::file("opt/tool/bin/tool"),
                PlacedPath::symlink("bin/tool", "../opt/tool/bin/tool"),
            ],
        );
        let plan = fp.uninstall_plan();
        assert_eq!(plan[0].path, "bin/tool"); // child/symlink first
        assert_eq!(plan[1].path, "opt/tool/bin/tool");
        assert_eq!(plan[2].path, "opt/tool"); // dir last
    }

    #[test]
    fn source_and_kind_round_trip() {
        for s in [
            FootprintSource::DeclaredManifest,
            FootprintSource::TracedExecution,
        ] {
            assert_eq!(FootprintSource::parse(s.as_str()), Some(s));
        }
        for k in [PathKind::File, PathKind::Dir, PathKind::Symlink] {
            assert_eq!(PathKind::parse(k.as_str()), Some(k));
        }
    }
}
