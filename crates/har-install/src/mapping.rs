// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Mapping tier-1 artifacts onto the [`har_meta`] resource schema.
//!
//! This is the "absorb into the meta-model" step. An [`InstallArtifact`]
//! becomes a `pkg.install` [`Resource`] whose scalar attributes carry every
//! field, and lifts back losslessly. ADR-0003 makes this the load-bearing
//! contract: tier 2 must *specialise* this schema without redesigning it — the
//! round-trip proven here (`to_resource ∘ from_resource = id`) is exactly what
//! a tier-2 regression test checks against.
//!
//! The dialect is scalar-only (v0.1), so the footprint's list of typed paths
//! is encoded as a `StrList` of tab-separated `kind\tpath[\ttarget]` records —
//! reversible, and free of the identifier charset restriction because these
//! are attribute *values*, not names.

use crate::artifact::{InstallArtifact, InstallMethod};
use crate::error::{Error, Result};
use crate::footprint::{Footprint, FootprintSource, PathKind, PlacedPath};
use crate::integrity::Integrity;
use crate::origin::InstallOrigin;
use crate::rerun::{RerunPolicy, VersionSpec};
use har_meta::{AttrValue, Resource, ResourceId, ResourceKind};

/// The tool-neutral kind every tier-1 artifact maps to.
pub const KIND: &str = "pkg.install";

fn encode_path(p: &PlacedPath) -> String {
    match p.kind {
        PathKind::File => format!("file\t{}", p.path),
        PathKind::Dir => format!("dir\t{}", p.path),
        PathKind::Symlink => format!(
            "symlink\t{}\t{}",
            p.path,
            p.link_target.as_deref().unwrap_or("")
        ),
    }
}

fn decode_path(s: &str) -> Result<PlacedPath> {
    let mut parts = s.split('\t');
    let kind = parts.next().unwrap_or("");
    let path = parts.next().ok_or(Error::BadAttr {
        attr: "footprint.paths",
        detail: format!("no path in record `{s}`"),
    })?;
    Ok(match kind {
        "file" => PlacedPath::file(path),
        "dir" => PlacedPath::dir(path),
        "symlink" => PlacedPath::symlink(path, parts.next().unwrap_or("")),
        other => {
            return Err(Error::BadAttr {
                attr: "footprint.paths",
                detail: format!("unknown path kind `{other}`"),
            })
        }
    })
}

/// Lower an artifact to its `pkg.install` resource.
pub fn to_resource(art: &InstallArtifact) -> Result<Resource> {
    let mut r = Resource::new(ResourceId::new(&art.id)?, ResourceKind::new(KIND)?)
        .with_attr("name", art.name.as_str())?
        .with_attr("version", art.version.as_str())?
        .with_attr("prefix", art.prefix.as_str())?
        .with_attr("rerun", art.rerun.as_str())?
        .with_attr("method", art.method.as_str())?
        .with_attr("origin.kind", art.origin.kind())?
        .with_attr("origin.locator", art.origin.locator())?
        .with_attr("integrity.kind", art.integrity.kind())?
        .with_attr("footprint.source", art.footprint.source.as_str())?
        .with_attr(
            "footprint.paths",
            art.footprint
                .paths
                .iter()
                .map(encode_path)
                .collect::<Vec<_>>(),
        )?;

    if let Some(rev) = art.origin.rev() {
        r = r.with_attr("origin.rev", rev)?;
    }
    match &art.integrity {
        Integrity::None => {}
        Integrity::Sha256 { hex } => {
            r = r.with_attr("integrity.hex", hex.as_str())?;
        }
        Integrity::Signature { scheme, locator } => {
            r = r
                .with_attr("integrity.scheme", scheme.as_str())?
                .with_attr("integrity.locator", locator.as_str())?;
        }
    }
    Ok(r)
}

fn attr_str<'a>(r: &'a Resource, name: &'static str) -> Result<&'a str> {
    match r.attributes.get(name) {
        Some(AttrValue::Str(s)) => Ok(s),
        Some(_) => Err(Error::BadAttr {
            attr: name,
            detail: "expected a string".to_string(),
        }),
        None => Err(Error::MissingAttr(name)),
    }
}

fn attr_str_opt<'a>(r: &'a Resource, name: &str) -> Option<&'a str> {
    match r.attributes.get(name) {
        Some(AttrValue::Str(s)) => Some(s),
        _ => None,
    }
}

/// Lift a `pkg.install` resource back to an artifact.
pub fn from_resource(r: &Resource) -> Result<InstallArtifact> {
    if r.kind.as_str() != KIND {
        return Err(Error::NotAnArtifact(r.kind.as_str().to_string()));
    }

    let origin = InstallOrigin::rebuild(
        attr_str(r, "origin.kind")?,
        attr_str(r, "origin.locator")?,
        attr_str_opt(r, "origin.rev"),
    )?;

    let integrity = match attr_str(r, "integrity.kind")? {
        "none" => Integrity::None,
        "sha256" => Integrity::Sha256 {
            hex: attr_str(r, "integrity.hex")?.to_string(),
        },
        "signature" => Integrity::Signature {
            scheme: attr_str(r, "integrity.scheme")?.to_string(),
            locator: attr_str(r, "integrity.locator")?.to_string(),
        },
        other => {
            return Err(Error::BadAttr {
                attr: "integrity.kind",
                detail: format!("unknown integrity kind `{other}`"),
            })
        }
    };

    let method = InstallMethod::parse(attr_str(r, "method")?).ok_or(Error::BadAttr {
        attr: "method",
        detail: "unknown install method".to_string(),
    })?;
    let rerun = RerunPolicy::parse(attr_str(r, "rerun")?).ok_or(Error::BadAttr {
        attr: "rerun",
        detail: "unknown rerun policy".to_string(),
    })?;
    let source =
        FootprintSource::parse(attr_str(r, "footprint.source")?).ok_or(Error::BadAttr {
            attr: "footprint.source",
            detail: "unknown footprint source".to_string(),
        })?;

    let paths = match r.attributes.get("footprint.paths") {
        Some(AttrValue::StrList(items)) => items
            .iter()
            .map(|s| decode_path(s))
            .collect::<Result<Vec<_>>>()?,
        Some(_) => {
            return Err(Error::BadAttr {
                attr: "footprint.paths",
                detail: "expected a string list".to_string(),
            })
        }
        None => Vec::new(),
    };

    Ok(InstallArtifact {
        id: r.id.as_str().to_string(),
        name: attr_str(r, "name")?.to_string(),
        version: VersionSpec::parse(attr_str(r, "version")?),
        prefix: attr_str(r, "prefix")?.to_string(),
        origin,
        method,
        integrity,
        footprint: Footprint::new(source, paths),
        rerun,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> InstallArtifact {
        InstallArtifact {
            id: "z3".to_string(),
            name: "z3".to_string(),
            version: VersionSpec::exact("4.13.0"),
            prefix: ".local".to_string(),
            origin: InstallOrigin::Tarball {
                url: "https://example.test/z3.tar.gz".to_string(),
            },
            method: InstallMethod::UnpackToPrefix,
            integrity: Integrity::Sha256 {
                hex: Integrity::sha256_of(b"z3"),
            },
            footprint: Footprint::new(
                FootprintSource::TracedExecution,
                vec![
                    PlacedPath::dir("opt/z3"),
                    PlacedPath::file("opt/z3/bin/z3"),
                    PlacedPath::symlink("bin/z3", "../opt/z3/bin/z3"),
                ],
            ),
            rerun: RerunPolicy::IdempotentSkip,
        }
    }

    #[test]
    fn round_trips_through_resource() {
        let art = sample();
        let r = to_resource(&art).unwrap();
        assert_eq!(r.kind.as_str(), KIND);
        let back = from_resource(&r).unwrap();
        assert_eq!(art, back);
    }

    #[test]
    fn round_trips_with_no_integrity_and_git_origin() {
        let mut art = sample();
        art.integrity = Integrity::None;
        art.origin = InstallOrigin::GitClone {
            repo: "https://example.test/r.git".to_string(),
            rev: "v1.0.0".to_string(),
        };
        art.version = VersionSpec::Latest;
        let r = to_resource(&art).unwrap();
        assert_eq!(from_resource(&r).unwrap(), art);
    }

    #[test]
    fn wrong_kind_is_rejected() {
        let r = Resource::new(
            ResourceId::new("x").unwrap(),
            ResourceKind::new("har.route").unwrap(),
        );
        assert!(matches!(from_resource(&r), Err(Error::NotAnArtifact(_))));
    }
}
