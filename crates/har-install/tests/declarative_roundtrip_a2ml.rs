// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

//! Tier-1 declarative round-trip (issue #97):
//! "ensure installed at version X" lowers to the imperative install, the
//! footprint is recorded, and lifting recovers the declaration — carried over
//! the A2ML interchange dialect the whole way, proving the tier-1 schema rides
//! on the meta-model's wire format without special-casing.

use chrono::{TimeZone, Utc};
use har_install::capture::{capture, FootprintStrategy, InstallSpec};
use har_install::{
    from_resource, to_resource, InstallMethod, InstallOrigin, Integrity, PlacedPath, RerunPolicy,
    SimulatedExecutor, VersionSpec,
};
use har_meta::{a2ml, Owner, ResourceGraph};

fn z3_spec() -> InstallSpec {
    // Declarative intent: "ensure z3 4.13.0 is installed".
    InstallSpec {
        id: "z3".to_string(),
        name: "z3".to_string(),
        version: VersionSpec::exact("4.13.0"),
        prefix: ".local".to_string(),
        origin: InstallOrigin::Tarball {
            url: "https://example.test/z3-4.13.0.tar.gz".to_string(),
        },
        method: InstallMethod::UnpackToPrefix,
        integrity: Integrity::None,
        rerun: RerunPolicy::IdempotentSkip,
        declared_paths: vec![
            PlacedPath::dir("opt/z3"),
            PlacedPath::file("opt/z3/bin/z3"),
            PlacedPath::symlink("bin/z3", "../opt/z3/bin/z3"),
        ],
    }
}

#[test]
fn declaration_lowers_records_and_lifts_over_a2ml() {
    // Lower: realise the imperative install and record the footprint.
    let mut ex = SimulatedExecutor::with_temp("a2ml-roundtrip").unwrap();
    let record = capture(&z3_spec(), FootprintStrategy::TracedExecution, &mut ex).unwrap();
    assert!(
        record.is_reproducible(),
        "pinned + footprint => reproducible"
    );

    // Map to a pkg.install resource and carry it on A2ML.
    let resource = to_resource(&record).unwrap();
    let mut graph = ResourceGraph::new();
    let at = Utc.with_ymd_and_hms(2026, 7, 7, 0, 0, 0).unwrap();
    graph
        .add_resource(resource, Owner::new("har-install").unwrap(), at)
        .unwrap();

    let wire = a2ml::emit(&graph).unwrap();
    assert!(wire.contains("pkg.install"), "dialect carries the kind");

    // Parse back off the wire and lift to an artifact: the declaration is
    // recovered byte-for-byte.
    let parsed = a2ml::parse(&wire).unwrap();
    let entry = parsed
        .get(&har_meta::ResourceId::new("z3").unwrap())
        .expect("z3 present after A2ML round-trip");
    let lifted = from_resource(&entry.resource).unwrap();

    assert_eq!(lifted, record, "lift recovers the recorded declaration");
    assert_eq!(lifted.version, VersionSpec::exact("4.13.0"));
    assert_eq!(lifted.footprint.paths.len(), 3);
}
