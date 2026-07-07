// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! The A2ML interchange dialect, v0.1
//!
//! A2ML's existing estate role is metadata/state checkpoints; ADR-0002
//! gives it a second role as the *interchange carrier* for the meta-model.
//! This module is the reference codec for dialect v0.1 (the normative prose
//! is `docs/architecture/A2ML-INTERCHANGE-DIALECT.adoc`).
//!
//! The dialect is deliberately small: a `[interlingua]` header, one
//! `[resource.<id>]` section per resource (current owner, status, optional
//! provider, scalar attributes), and one `[dependency.<n>]` section per
//! edge. Provenance *history* and handoff checkpoints are not carried in
//! v0.1 — the dialect moves the current shared view; checkpoint metadata
//! arrives with the handoff engine.
//!
//! Emission is deterministic: resources in id order, attributes in name
//! order, dependencies in insertion order. `parse(emit(g))` reproduces `g`
//! up to provenance history, and `emit` is idempotent across a round-trip.

use crate::dependency::{Dependency, DependencyKind};
use crate::error::{Error, Result};
use crate::graph::{ResourceEntry, ResourceGraph};
use crate::provenance::{Owner, Provenance, Provider};
use crate::resource::{AttrValue, Resource, ResourceId, ResourceKind};
use crate::state::RealisationStatus;
use std::fmt::Write as _;

/// Dialect name carried in the `[interlingua]` header
pub const DIALECT: &str = "har-interlingua";
/// Dialect version this codec reads and writes
pub const VERSION: &str = "0.1";

/// Serialise a resource graph to A2ML interchange text
pub fn emit(graph: &ResourceGraph) -> Result<String> {
    let mut out = String::new();
    out.push_str("# har-interlingua — A2ML interchange dialect\n");
    out.push_str("[interlingua]\n");
    let _ = writeln!(out, "dialect = {}", quote(DIALECT));
    let _ = writeln!(out, "version = {}", quote(VERSION));
    let _ = writeln!(out, "kind = {}", quote("resource-graph"));

    for entry in graph.entries() {
        out.push('\n');
        let _ = writeln!(out, "[resource.{}]", entry.resource.id);
        let _ = writeln!(out, "kind = {}", quote(entry.resource.kind.as_str()));
        let _ = writeln!(out, "owner = {}", quote(entry.provenance.owner.as_str()));
        let _ = writeln!(out, "status = {}", quote(entry.provenance.status.as_str()));
        if let Some(provider) = &entry.provider {
            let _ = writeln!(out, "provider = {}", quote(provider.as_str()));
        }
        for (name, value) in &entry.resource.attributes {
            let _ = writeln!(out, "attr.{name} = {}", emit_value(value));
        }
    }

    for (n, dep) in graph.dependencies().iter().enumerate() {
        out.push('\n');
        let _ = writeln!(out, "[dependency.{}]", n + 1);
        let _ = writeln!(out, "from = {}", quote(dep.from.as_str()));
        let _ = writeln!(out, "to = {}", quote(dep.to.as_str()));
        let _ = writeln!(out, "relation = {}", quote(dep.kind.as_str()));
    }
    Ok(out)
}

/// Parse A2ML interchange text into a resource graph
///
/// Section order is free (dependencies may precede the resources they
/// name); the `[interlingua]` header must be present with a matching
/// dialect and version. Provenance histories start empty — v0.1 does not
/// carry them.
pub fn parse(text: &str) -> Result<ResourceGraph> {
    let mut header: Option<Section> = None;
    let mut resources: Vec<Section> = Vec::new();
    let mut dependencies: Vec<Section> = Vec::new();

    for section in split_sections(text)? {
        match section.name.as_str() {
            "interlingua" => {
                if header.is_some() {
                    return Err(parse_err(section.line, "duplicate [interlingua] header"));
                }
                header = Some(section);
            }
            "resource" => resources.push(section),
            "dependency" => dependencies.push(section),
            other => {
                return Err(parse_err(
                    section.line,
                    format!("unknown section [{other}]"),
                ));
            }
        }
    }

    let header = header.ok_or_else(|| parse_err(1, "missing [interlingua] header"))?;
    check_header(&header)?;

    let mut graph = ResourceGraph::new();
    for section in resources {
        graph.insert_entry(resource_entry(section)?)?;
    }
    for section in dependencies {
        graph.add_dependency(dependency(section)?)?;
    }
    Ok(graph)
}

/// One parsed `[name.qualifier]` section with its key/value pairs
struct Section {
    name: String,
    qualifier: String,
    line: usize,
    pairs: Vec<(String, Value, usize)>,
}

impl Section {
    /// Fetch a required string-valued key
    fn require_str(&self, key: &str) -> Result<&str> {
        for (k, v, line) in &self.pairs {
            if k == key {
                if let Value::Str(s) = v {
                    return Ok(s);
                }
                return Err(parse_err(*line, format!("{key} must be a string")));
            }
        }
        Err(parse_err(
            self.line,
            format!("[{}.{}] is missing {key}", self.name, self.qualifier),
        ))
    }

    /// Fetch an optional string-valued key
    fn optional_str(&self, key: &str) -> Result<Option<&str>> {
        for (k, v, line) in &self.pairs {
            if k == key {
                if let Value::Str(s) = v {
                    return Ok(Some(s));
                }
                return Err(parse_err(*line, format!("{key} must be a string")));
            }
        }
        Ok(None)
    }
}

/// A parsed value: the dialect's scalar universe
enum Value {
    Bool(bool),
    Int(i64),
    Str(String),
    StrList(Vec<String>),
}

impl From<Value> for AttrValue {
    fn from(v: Value) -> Self {
        match v {
            Value::Bool(b) => AttrValue::Bool(b),
            Value::Int(i) => AttrValue::Int(i),
            Value::Str(s) => AttrValue::Str(s),
            Value::StrList(l) => AttrValue::StrList(l),
        }
    }
}

fn parse_err(line: usize, message: impl Into<String>) -> Error {
    Error::Parse {
        line,
        message: message.into(),
    }
}

fn check_header(header: &Section) -> Result<()> {
    let dialect = header.require_str("dialect")?;
    if dialect != DIALECT {
        return Err(parse_err(
            header.line,
            format!("dialect {dialect:?} is not {DIALECT:?}"),
        ));
    }
    let version = header.require_str("version")?;
    if version != VERSION {
        return Err(parse_err(
            header.line,
            format!("version {version:?} is not supported (codec reads {VERSION})"),
        ));
    }
    for (key, _, line) in &header.pairs {
        if !matches!(key.as_str(), "dialect" | "version" | "kind") {
            return Err(parse_err(*line, format!("unknown header key {key:?}")));
        }
    }
    Ok(())
}

fn resource_entry(section: Section) -> Result<ResourceEntry> {
    let id = ResourceId::new(section.qualifier.clone()).map_err(|_| {
        parse_err(
            section.line,
            format!("invalid resource id {:?}", section.qualifier),
        )
    })?;
    let kind = ResourceKind::new(section.require_str("kind")?)
        .map_err(|_| parse_err(section.line, "invalid resource kind"))?;
    let owner = Owner::new(section.require_str("owner")?)
        .map_err(|_| parse_err(section.line, "invalid owner"))?;
    let status_str = section.require_str("status")?;
    let status = RealisationStatus::parse(status_str)
        .ok_or_else(|| parse_err(section.line, format!("unknown status {status_str:?}")))?;
    let provider = match section.optional_str("provider")? {
        Some(p) => Some(Provider::new(p).map_err(|_| parse_err(section.line, "invalid provider"))?),
        None => None,
    };

    let mut resource = Resource::new(id, kind);
    for (key, value, line) in section.pairs {
        if let Some(attr) = key.strip_prefix("attr.") {
            resource = resource
                .with_attr(attr, AttrValue::from(value))
                .map_err(|_| parse_err(line, format!("invalid attribute name {attr:?}")))?;
        } else if !matches!(key.as_str(), "kind" | "owner" | "status" | "provider") {
            return Err(parse_err(line, format!("unknown resource key {key:?}")));
        }
    }

    Ok(ResourceEntry {
        resource,
        provenance: Provenance {
            owner,
            status,
            history: Vec::new(),
        },
        provider,
    })
}

fn dependency(section: Section) -> Result<Dependency> {
    let from = ResourceId::new(section.require_str("from")?)
        .map_err(|_| parse_err(section.line, "invalid from id"))?;
    let to = ResourceId::new(section.require_str("to")?)
        .map_err(|_| parse_err(section.line, "invalid to id"))?;
    let relation = section.require_str("relation")?;
    let kind = DependencyKind::parse(relation)
        .ok_or_else(|| parse_err(section.line, format!("unknown relation {relation:?}")))?;
    for (key, _, line) in &section.pairs {
        if !matches!(key.as_str(), "from" | "to" | "relation") {
            return Err(parse_err(*line, format!("unknown dependency key {key:?}")));
        }
    }
    Ok(Dependency::new(from, to, kind))
}

fn split_sections(text: &str) -> Result<Vec<Section>> {
    let mut sections: Vec<Section> = Vec::new();
    for (idx, raw) in text.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(inner) = line.strip_prefix('[') {
            let inner = inner
                .strip_suffix(']')
                .ok_or_else(|| parse_err(line_no, "unterminated section header"))?;
            let (name, qualifier) = match inner.split_once('.') {
                Some((n, q)) => (n.to_string(), q.to_string()),
                None => (inner.to_string(), String::new()),
            };
            sections.push(Section {
                name,
                qualifier,
                line: line_no,
                pairs: Vec::new(),
            });
        } else {
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| parse_err(line_no, "expected key = value"))?;
            let section = sections
                .last_mut()
                .ok_or_else(|| parse_err(line_no, "key/value before any section"))?;
            section.pairs.push((
                key.trim().to_string(),
                parse_value(value.trim(), line_no)?,
                line_no,
            ));
        }
    }
    Ok(sections)
}

fn parse_value(s: &str, line: usize) -> Result<Value> {
    if s == "true" {
        return Ok(Value::Bool(true));
    }
    if s == "false" {
        return Ok(Value::Bool(false));
    }
    if s.starts_with('"') {
        return Ok(Value::Str(parse_string(s, line)?));
    }
    if s.starts_with('[') {
        let inner = s
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .ok_or_else(|| parse_err(line, "unterminated list"))?
            .trim();
        if inner.is_empty() {
            return Ok(Value::StrList(Vec::new()));
        }
        let mut items = Vec::new();
        for item in split_list_items(inner, line)? {
            items.push(parse_string(&item, line)?);
        }
        return Ok(Value::StrList(items));
    }
    s.parse::<i64>()
        .map(Value::Int)
        .map_err(|_| parse_err(line, format!("unrecognised value {s:?}")))
}

/// Split a list body on commas that sit between (not inside) quoted strings
fn split_list_items(inner: &str, line: usize) -> Result<Vec<String>> {
    let mut items = Vec::new();
    let mut current = String::new();
    let mut in_string = false;
    let mut escaped = false;
    for c in inner.chars() {
        if in_string {
            current.push(c);
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
        } else {
            match c {
                ',' => {
                    let item = current.trim().to_string();
                    if item.is_empty() {
                        return Err(parse_err(line, "empty list item"));
                    }
                    items.push(item);
                    current = String::new();
                }
                '"' => {
                    in_string = true;
                    current.push(c);
                }
                c if c.is_whitespace() => {}
                other => return Err(parse_err(line, format!("unexpected {other:?} in list"))),
            }
        }
    }
    if in_string {
        return Err(parse_err(line, "unterminated string in list"));
    }
    let item = current.trim().to_string();
    if item.is_empty() {
        return Err(parse_err(line, "empty list item"));
    }
    items.push(item);
    Ok(items)
}

fn parse_string(s: &str, line: usize) -> Result<String> {
    let inner = s
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .ok_or_else(|| parse_err(line, format!("expected quoted string, got {s:?}")))?;
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '"' {
            return Err(parse_err(line, "unescaped quote inside string"));
        }
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('\\') => out.push('\\'),
            Some('"') => out.push('"'),
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            other => {
                return Err(parse_err(
                    line,
                    format!(
                        "unknown escape \\{}",
                        other.map(String::from).unwrap_or_default()
                    ),
                ))
            }
        }
    }
    Ok(out)
}

fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

fn emit_value(value: &AttrValue) -> String {
    match value {
        AttrValue::Bool(b) => b.to_string(),
        AttrValue::Int(i) => i.to_string(),
        AttrValue::Str(s) => quote(s),
        AttrValue::StrList(items) => {
            let quoted: Vec<String> = items.iter().map(|s| quote(s)).collect();
            format!("[{}]", quoted.join(", "))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, Utc};

    fn t0() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-07-07T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    fn sample() -> ResourceGraph {
        let mut g = ResourceGraph::new();
        let route = Resource::new(
            ResourceId::new("web-route").unwrap(),
            ResourceKind::new("har.route").unwrap(),
        )
        .with_attr("target", "rpa-elysium")
        .unwrap()
        .with_attr("priority", 5_i64)
        .unwrap()
        .with_attr("enabled", true)
        .unwrap()
        .with_attr(
            "tags",
            vec!["web".to_string(), "a \"quoted\" tag".to_string()],
        )
        .unwrap();
        let queue = Resource::new(
            ResourceId::new("queue-conn").unwrap(),
            ResourceKind::new("har.queue").unwrap(),
        );
        g.add_resource(route, Owner::new("har").unwrap(), t0())
            .unwrap();
        g.add_resource(queue, Owner::new("har").unwrap(), t0())
            .unwrap();
        g.set_provider(
            &ResourceId::new("queue-conn").unwrap(),
            Provider::new("proven-queueconn").unwrap(),
        )
        .unwrap();
        g.add_dependency(Dependency::new(
            ResourceId::new("web-route").unwrap(),
            ResourceId::new("queue-conn").unwrap(),
            DependencyKind::Require,
        ))
        .unwrap();
        g
    }

    #[test]
    fn test_round_trip_semantics() {
        let g = sample();
        let text = emit(&g).unwrap();
        let parsed = parse(&text).unwrap();
        assert_eq!(parsed.len(), g.len());
        for entry in g.entries() {
            let p = parsed.get(&entry.resource.id).unwrap();
            assert_eq!(p.resource, entry.resource);
            assert_eq!(p.provenance.owner, entry.provenance.owner);
            assert_eq!(p.provenance.status, entry.provenance.status);
            assert_eq!(p.provider, entry.provider);
        }
        assert_eq!(parsed.dependencies(), g.dependencies());
    }

    #[test]
    fn test_emit_idempotent_across_round_trip() {
        let text = emit(&sample()).unwrap();
        assert_eq!(emit(&parse(&text).unwrap()).unwrap(), text);
    }

    #[test]
    fn test_section_order_free() {
        let text = r#"
[interlingua]
dialect = "har-interlingua"
version = "0.1"
kind = "resource-graph"

[dependency.1]
from = "a"
to = "b"
relation = "before"

[resource.b]
kind = "har.route"
owner = "har"
status = "declared"

[resource.a]
kind = "har.route"
owner = "har"
status = "planned"
"#;
        let g = parse(text).unwrap();
        assert_eq!(g.len(), 2);
        assert_eq!(g.dependencies().len(), 1);
    }

    #[test]
    fn test_header_enforced() {
        assert!(matches!(
            parse("[resource.a]\nkind = \"k\"\nowner = \"o\"\nstatus = \"declared\"\n"),
            Err(Error::Parse { .. })
        ));
        let wrong_version = "[interlingua]\ndialect = \"har-interlingua\"\nversion = \"9.9\"\n";
        assert!(matches!(parse(wrong_version), Err(Error::Parse { .. })));
    }

    #[test]
    fn test_bad_input_rejected() {
        let header = "[interlingua]\ndialect = \"har-interlingua\"\nversion = \"0.1\"\n";
        for bad in [
            "[mystery.x]\n",
            "[resource.a]\nkind = \"k\"\nowner = \"o\"\nstatus = \"flying\"\n",
            "[resource.a]\nkind = \"k\"\nowner = \"o\"\nstatus = \"declared\"\nbogus = \"x\"\n",
            "[resource.a\n",
            "no_section = true\n",
        ] {
            let text = format!("{header}{bad}");
            assert!(parse(&text).is_err(), "expected rejection of {bad:?}");
        }
        // Key/value before any section (no header at all)
        assert!(parse("stray = 1\n").is_err());
    }

    #[test]
    fn test_string_escapes() {
        let g = {
            let mut g = ResourceGraph::new();
            let r = Resource::new(
                ResourceId::new("r").unwrap(),
                ResourceKind::new("k").unwrap(),
            )
            .with_attr("tricky", "line1\nline2\t\"quoted\" \\slash")
            .unwrap();
            g.add_resource(r, Owner::new("har").unwrap(), t0()).unwrap();
            g
        };
        let parsed = parse(&emit(&g).unwrap()).unwrap();
        let entry = parsed.get(&ResourceId::new("r").unwrap()).unwrap();
        assert_eq!(
            entry.resource.attributes["tricky"],
            AttrValue::Str("line1\nline2\t\"quoted\" \\slash".to_string())
        );
    }
}
