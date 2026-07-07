// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Where a tier-1 artifact comes from.
//!
//! Tier 1 (ADR-0003) is the package-manager-less end of the ladder: there is
//! no registry and no manager, so the origin is a bare locator — a script URL,
//! a tarball, a git ref. The variants here enumerate the manager-less channels
//! called out in the tier-1 scope of issue #97.
//!
//! Because the A2ML dialect (v0.1) and the meta-model attribute space are
//! scalar-only, an origin flattens to three attributes: a `kind` tag, a
//! `locator` (the URL, or the repository for a clone / build), and an optional
//! `rev` (the pinned git revision). The [`InstallOrigin::kind`] /
//! [`InstallOrigin::locator`] / [`InstallOrigin::rev`] projection and
//! [`InstallOrigin::rebuild`] are the two halves of that reversible mapping.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};

/// The manager-less acquisition channel of a tier-1 artifact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum InstallOrigin {
    /// A `curl | sh` / `wget | bash` vendor install script (rustup-, deno-,
    /// ollama-style). The most opaque origin: the script's footprint is only
    /// knowable by tracing.
    ScriptPipe {
        /// URL the script is fetched from.
        url: String,
    },
    /// A tarball (`.tar.*`) unpacked and hand-placed on `PATH`.
    Tarball {
        /// URL of the archive.
        url: String,
    },
    /// A zip archive unpacked and hand-placed on `PATH`.
    Zip {
        /// URL of the archive.
        url: String,
    },
    /// A single self-contained binary dropped onto `PATH` (includes
    /// AppImage-style no-install artefacts — see [`InstallOrigin::AppImage`]
    /// for the AppImage-specific tag).
    BinaryDrop {
        /// URL of the binary.
        url: String,
    },
    /// An AppImage: a single relocatable artefact that is run in place.
    AppImage {
        /// URL of the `.AppImage`.
        url: String,
    },
    /// `./configure && make && make install` from a source tree.
    ConfigureMake {
        /// URL of the source archive or checkout.
        source_url: String,
    },
    /// `git clone` at a pinned revision, then a symlink arrangement.
    GitClone {
        /// Repository URL.
        repo: String,
        /// Pinned revision (tag/commit) — never a moving branch, so the
        /// origin is reproducible.
        rev: String,
    },
}

impl InstallOrigin {
    /// The stable kebab-case tag carried in the `origin.kind` attribute.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::ScriptPipe { .. } => "script-pipe",
            Self::Tarball { .. } => "tarball",
            Self::Zip { .. } => "zip",
            Self::BinaryDrop { .. } => "binary-drop",
            Self::AppImage { .. } => "appimage",
            Self::ConfigureMake { .. } => "configure-make",
            Self::GitClone { .. } => "git-clone",
        }
    }

    /// The primary locator (URL, or repository for clone/build).
    pub fn locator(&self) -> &str {
        match self {
            Self::ScriptPipe { url }
            | Self::Tarball { url }
            | Self::Zip { url }
            | Self::BinaryDrop { url }
            | Self::AppImage { url } => url,
            Self::ConfigureMake { source_url } => source_url,
            Self::GitClone { repo, .. } => repo,
        }
    }

    /// The pinned revision, present only for [`InstallOrigin::GitClone`].
    pub fn rev(&self) -> Option<&str> {
        match self {
            Self::GitClone { rev, .. } => Some(rev),
            _ => None,
        }
    }

    /// Rebuild an origin from its flattened `(kind, locator, rev)` triple —
    /// the inverse of the [`InstallOrigin::kind`] / [`InstallOrigin::locator`]
    /// / [`InstallOrigin::rev`] projection used when mapping to the meta-model.
    pub fn rebuild(kind: &str, locator: &str, rev: Option<&str>) -> Result<Self> {
        let url = locator.to_string();
        Ok(match kind {
            "script-pipe" => Self::ScriptPipe { url },
            "tarball" => Self::Tarball { url },
            "zip" => Self::Zip { url },
            "binary-drop" => Self::BinaryDrop { url },
            "appimage" => Self::AppImage { url },
            "configure-make" => Self::ConfigureMake { source_url: url },
            "git-clone" => Self::GitClone {
                repo: url,
                rev: rev.ok_or(Error::MissingAttr("origin.rev"))?.to_string(),
            },
            other => {
                return Err(Error::BadAttr {
                    attr: "origin.kind",
                    detail: format!("unknown origin kind `{other}`"),
                })
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_all_kinds() {
        let cases = [
            InstallOrigin::ScriptPipe {
                url: "https://example.test/i.sh".into(),
            },
            InstallOrigin::Tarball {
                url: "https://example.test/a.tar.gz".into(),
            },
            InstallOrigin::Zip {
                url: "https://example.test/a.zip".into(),
            },
            InstallOrigin::BinaryDrop {
                url: "https://example.test/tool".into(),
            },
            InstallOrigin::AppImage {
                url: "https://example.test/tool.AppImage".into(),
            },
            InstallOrigin::ConfigureMake {
                source_url: "https://example.test/src.tar.gz".into(),
            },
            InstallOrigin::GitClone {
                repo: "https://example.test/r.git".into(),
                rev: "v1.2.3".into(),
            },
        ];
        for o in cases {
            let back = InstallOrigin::rebuild(o.kind(), o.locator(), o.rev()).unwrap();
            assert_eq!(o, back);
        }
    }

    #[test]
    fn git_clone_requires_rev() {
        assert!(InstallOrigin::rebuild("git-clone", "https://x.git", None).is_err());
    }

    #[test]
    fn unknown_kind_rejected() {
        assert!(InstallOrigin::rebuild("apt", "ripgrep", None).is_err());
    }
}
