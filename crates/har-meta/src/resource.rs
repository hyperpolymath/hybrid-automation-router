// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Resources — the nodes of the declarative level
//!
//! A [`Resource`] is a desired thing: a route, a package install, a file, a
//! service. Its [`ResourceKind`] names which tool-neutral concept it maps to
//! (namespaced, e.g. `har.route`, `pkg.install`); its attributes carry the
//! desired configuration.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Charset shared by meta-model identifiers: ASCII alphanumerics plus
/// `-`, `_`, `.`, `:`. Keeps every identifier representable in the A2ML
/// dialect and in section headers without escaping.
fn valid_ident(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':'))
}

/// Unique identifier of a resource within a graph
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ResourceId(String);

impl ResourceId {
    /// Create a resource id, validating the identifier charset
    pub fn new(id: impl Into<String>) -> Result<Self> {
        let id = id.into();
        if valid_ident(&id) {
            Ok(Self(id))
        } else {
            Err(Error::InvalidIdentifier {
                what: "resource id",
                value: id,
            })
        }
    }

    /// The id as a string slice
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ResourceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Tool-neutral kind of a resource (namespaced, e.g. `har.route`)
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ResourceKind(String);

impl ResourceKind {
    /// Create a resource kind, validating the identifier charset
    pub fn new(kind: impl Into<String>) -> Result<Self> {
        let kind = kind.into();
        if valid_ident(&kind) {
            Ok(Self(kind))
        } else {
            Err(Error::InvalidIdentifier {
                what: "resource kind",
                value: kind,
            })
        }
    }

    /// The kind as a string slice
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ResourceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// An attribute value
///
/// Dialect v0.1 is deliberately scalar: strings, integers, booleans, and
/// lists of strings. Nested maps are excluded until a consuming domain needs
/// them (they would then arrive together with a dialect version bump).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AttrValue {
    /// Boolean flag
    Bool(bool),
    /// Signed integer
    Int(i64),
    /// UTF-8 string
    Str(String),
    /// List of strings
    StrList(Vec<String>),
}

impl From<bool> for AttrValue {
    fn from(v: bool) -> Self {
        Self::Bool(v)
    }
}

impl From<i64> for AttrValue {
    fn from(v: i64) -> Self {
        Self::Int(v)
    }
}

impl From<&str> for AttrValue {
    fn from(v: &str) -> Self {
        Self::Str(v.to_string())
    }
}

impl From<String> for AttrValue {
    fn from(v: String) -> Self {
        Self::Str(v)
    }
}

impl From<Vec<String>> for AttrValue {
    fn from(v: Vec<String>) -> Self {
        Self::StrList(v)
    }
}

/// A desired resource: the node type of the declarative graph
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resource {
    /// Unique id within the graph
    pub id: ResourceId,
    /// Tool-neutral kind
    pub kind: ResourceKind,
    /// Desired configuration (attribute names share the identifier charset;
    /// `BTreeMap` keeps emission deterministic)
    pub attributes: BTreeMap<String, AttrValue>,
}

impl Resource {
    /// Create a resource with no attributes
    pub fn new(id: ResourceId, kind: ResourceKind) -> Self {
        Self {
            id,
            kind,
            attributes: BTreeMap::new(),
        }
    }

    /// Set an attribute, validating the attribute name's charset
    pub fn with_attr(
        mut self,
        name: impl Into<String>,
        value: impl Into<AttrValue>,
    ) -> Result<Self> {
        let name = name.into();
        if !valid_ident(&name) {
            return Err(Error::InvalidIdentifier {
                what: "attribute name",
                value: name,
            });
        }
        self.attributes.insert(name, value.into());
        Ok(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_id_charset() {
        assert!(ResourceId::new("web-route_1.a:b").is_ok());
        assert!(ResourceId::new("").is_err());
        assert!(ResourceId::new("has space").is_err());
        assert!(ResourceId::new("has]bracket").is_err());
    }

    #[test]
    fn test_attr_name_charset() {
        let r = Resource::new(
            ResourceId::new("r1").unwrap(),
            ResourceKind::new("har.route").unwrap(),
        );
        assert!(r.clone().with_attr("target", "rpa-elysium").is_ok());
        assert!(r.with_attr("bad name", "x").is_err());
    }
}
